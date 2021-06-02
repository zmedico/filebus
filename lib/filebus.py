import argparse
import array
import asyncio
import functools
import io
import logging
import os
import signal
import stat
import sys
import tarfile

try:
    import fcntl
except ImportError:
    fcntl = None

import filelock

try:
    from watchdog.events import FileSystemEventHandler
    import watchdog.observers
except ImportError:
    watchdog = None
    FileSystemEventHandler = object

__version__ = "0.0.5"
__project__ = "filebus"
__description__ = (
    "A user space multicast named pipe implementation backed by a regular file"
)
__author__ = "Zac Medico"
__email__ = "<zmedico@gmail.com>"
__copyright__ = "Copyright 2021 Zac Medico"
__license__ = "Apache-2.0"

BUFSIZE = 4096
SLEEP_INTERVAL = 0.1


class ModifiedFileHandler(FileSystemEventHandler):
    def __init__(self, filebus_callback=None, **kwargs):
        super().__init__(**kwargs)
        self.filebus_callback = filebus_callback

    def on_modified(self, event):
        super().on_modified(event)
        self.filebus_callback(event)


class FileBus:
    def __init__(self, args):
        self._args = args
        self._file_modified_future = None

    @property
    def _file_monitoring(self):
        return self._args.file_monitoring and watchdog is not None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, exc_traceback):
        return False

    async def io_loop(self):
        command_loop = getattr(self, self._args.command + "_loop")
        await command_loop()

    def _stdin_read(self, stdin, stdin_buffer, new_bytes, eof):
        try:
            result = os.read(stdin.fileno(), self._args.block_size)
        except EnvironmentError:
            result = None
        if result:
            stdin_buffer.extend(result)
        if not new_bytes.done():
            new_bytes.set_result(bool(result))
        result != b"" or eof.done() or eof.set_result(result)
        logging.debug("_stdin_read: %s", repr(result))

    def _lock_filename(self):
        lock = filelock.FileLock(self._args.filename + ".lock")
        lock.acquire()
        return lock

    async def _flush_buffer(self, stdin_buffer):
        stdin_bytes = stdin_buffer.tobytes()
        del stdin_buffer[:]

        with self._lock_filename() as lock:

            with tarfile.open(self._args.filename + ".__new__", mode="w") as tar:
                tarinfo = tar.tarinfo()
                tarinfo.name = "from_server"
                tarinfo.size = len(stdin_bytes)
                tar.addfile(tarinfo, io.BytesIO(stdin_bytes))

            os.rename(self._args.filename + ".__new__", self._args.filename)
            lock.release(force=True)

    async def producer_loop(self):

        # NOTE: This is a reference implementation which is optimized
        # for correctness, not throughput.
        loop = asyncio.get_event_loop()
        stdin = sys.stdin.buffer
        stdin_st = os.fstat(stdin.fileno())
        stdin_buffer = array.array("B")
        async_read = None
        maybe_async_read = (
            self._args.blocking_read is not False
            and fcntl is not None
            and hasattr(os, "O_NONBLOCK")
            and any(
                can_async(stdin_st.st_mode)
                for can_async in (stat.S_ISCHR, stat.S_ISFIFO, stat.S_ISSOCK)
            )
        )
        if maybe_async_read:
            try:
                fcntl.fcntl(
                    stdin.fileno(),
                    fcntl.F_SETFL,
                    fcntl.fcntl(stdin.fileno(), fcntl.F_GETFL) | os.O_NONBLOCK,
                )
            except Exception:
                logging.exception(
                    "async read disabled due to fcntl exception:",
                )
            else:
                try:
                    loop.add_reader(
                        stdin.fileno(),
                        lambda: None,
                    )
                except Exception:
                    logging.exception(
                        "async read disabled due to add_reader exception:",
                    )
                else:
                    async_read = True

                loop.remove_reader(stdin.fileno())

        eof = loop.create_future()
        while not (loop.is_closed() or eof.done()):

            new_bytes = loop.create_future()
            if async_read:
                loop.add_reader(
                    stdin.fileno(),
                    functools.partial(
                        self._stdin_read, stdin, stdin_buffer, new_bytes, eof
                    ),
                )
            try:
                if async_read:
                    await asyncio.wait([new_bytes], timeout=self._args.sleep_interval)
                    logging.debug(
                        "producer_loop post wait: len(stdin_buffer): %s new_bytes: %s",
                        len(stdin_buffer),
                        new_bytes.result() if new_bytes.done() else False,
                    )
                else:
                    self._stdin_read(stdin, stdin_buffer, new_bytes, eof)
                    if not new_bytes.result():
                        break

                if len(stdin_buffer):
                    if (
                        not new_bytes.done()
                        or not new_bytes.result()
                        or len(stdin_buffer) >= self._args.block_size
                    ):
                        await self._flush_buffer(stdin_buffer)

                if not new_bytes.done():
                    await new_bytes
            finally:
                if not loop.is_closed():
                    new_bytes.done() or new_bytes.cancel()

        if stdin_buffer:
            await self._flush_buffer(stdin_buffer)

    def _file_modified_callback(self, event):
        self._file_modified_future.done() or self._file_modified_future.set_result(True)
        logging.debug("Modified: %s", event.src_path)

    async def consumer_loop(self):
        loop = asyncio.get_event_loop()
        observer = None

        if self._file_monitoring:
            observer = watchdog.observers.Observer()
            observer.schedule(
                ModifiedFileHandler(
                    functools.partial(
                        loop.call_soon_threadsafe, self._file_modified_callback
                    )
                ),
                self._args.filename,
            )
            observer.start()

        try:
            previous_st = None
            while True:
                if self._file_monitoring:
                    self._file_modified_future = loop.create_future()
                else:
                    self._file_modified_future = None

                with self._lock_filename() as lock, open(
                    self._args.filename, "rb"
                ) as fileobj:
                    st = os.fstat(fileobj.fileno())
                    if st.st_size > 0 and not (
                        previous_st and previous_st.st_ino == st.st_ino
                    ):
                        with tarfile.open(
                            self._args.filename, fileobj=fileobj, mode="r"
                        ) as tar:

                            for tarinfo in tar:
                                if tarinfo.name == "from_server":
                                    previous_st = st
                                    try:
                                        sys.stdout.buffer.write(tar.extractfile(tarinfo).read())
                                        sys.stdout.buffer.flush()
                                    except BrokenPipeError:
                                        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
                                        os.kill(os.getpid(), signal.SIGPIPE)
                                        raise

                    lock.release(force=True)

                if self._file_modified_future is None:
                    await asyncio.sleep(self._args.sleep_interval)
                else:
                    try:
                        await asyncio.wait_for(
                            self._file_modified_future, self._args.sleep_interval
                        )
                    except asyncio.TimeoutError:
                        continue
        finally:
            if observer is not None:
                observer.stop()
                observer.join()


def numeric_arg(arg):
    for numeric_type in (int, float):
        try:
            return numeric_type(arg)
        except Exception:
            pass
    raise TypeError("Not a number: {}".format(arg))


def parse_args(argv=None):
    if argv is None:
        argv = sys.argv

    root_parser = argparse.ArgumentParser(
        prog=os.path.basename(argv[0]),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="  {} {}\n  {}".format(__project__, __version__, __description__),
    )

    root_parser.add_argument(
        "--block-size",
        action="store",
        metavar="N",
        type=int,
        default=BUFSIZE,
        help="maximum block size in units of bytes",
    )

    root_parser.add_argument(
        "--no-file-monitoring",
        action="store_false",
        dest="file_monitoring",
        default=True,
        help="disable filesystem event monitoring",
    )

    root_parser.add_argument(
        "--filename",
        action="store",
        metavar="FILE",
        default=None,
        help="path of the data file (the producer updates it via atomic rename)",
    )

    root_parser.add_argument(
        "--sleep-interval",
        action="store",
        metavar="N",
        type=numeric_arg,
        default=numeric_arg(SLEEP_INTERVAL),
        help="check for new messages at least once every N seconds",
    )

    root_parser.add_argument(
        "-v",
        "--verbose",
        dest="verbosity",
        action="count",
        help="verbose logging (each occurence increases verbosity)",
        default=0,
    )

    subparsers = root_parser.add_subparsers()
    producer_parser = subparsers.add_parser(
        "producer", help="connect producer side of stream"
    )
    producer_parser.set_defaults(func=lambda args: setattr(args, "command", "producer"))
    producer_parser.add_argument(
        "--blocking-read",
        action="store_true",
        dest="blocking_read",
        default=None,
        help="blocking read from input (clear the O_NONBLOCK flag)",
    )
    consumer_parser = subparsers.add_parser(
        "consumer", help="connect consumer side of stream"
    )
    consumer_parser.set_defaults(func=lambda args: setattr(args, "command", "consumer"))

    args = root_parser.parse_args(argv[1:])
    args.func(args)

    logging.basicConfig(
        level=(logging.getLogger().getEffectiveLevel() - 10 * args.verbosity),
        format="[%(levelname)-4s] %(message)s",
    )

    return args


def main():
    args = parse_args()
    loop = asyncio.get_event_loop()

    try:
        with FileBus(args) as bus:
            loop.run_until_complete(bus.io_loop())
    except KeyboardInterrupt:
        loop.stop()
    finally:
        loop.close()


if __name__ == "__main__":
    sys.exit(main())
