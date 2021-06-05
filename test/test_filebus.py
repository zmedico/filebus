import asyncio
import multiprocessing
import os
import sys
import tempfile
import unittest

try:
    import fcntl
except ImportError:
    fcntl = None

try:
    from filebus import FileBus, parse_args
except ImportError:
    sys.path.append(
        os.path.join(
            os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "lib/python"
        )
    )
    from filebus import FileBus, parse_args


class FileBusTest(unittest.TestCase):
    def test_filebus(self):
        asyncio.get_event_loop().run_until_complete(self._test_async())

    def test_filebus_back_pressure(self):
        asyncio.get_event_loop().run_until_complete(
            self._test_async(back_pressure=True)
        )

    def test_filebus_blocking_read(self):
        asyncio.get_event_loop().run_until_complete(
            self._test_async(force_blocking_read=True)
        )

    async def _test_async(self, back_pressure=False, force_blocking_read=False):
        with tempfile.NamedTemporaryFile() as data_file:
            if back_pressure:
                os.unlink(data_file.name)

            input_string = b"hello world\n"
            producer_args = parse_args(
                [
                    "filebus",
                ]
                + (["--back-pressure"] if back_pressure else [])
                + [
                    "--block-size=512",
                    "--sleep-interval=0.1",
                    "--filename",
                    data_file.name,
                    "producer",
                ]
                + (["--blocking-read"] if force_blocking_read else [])
            )
            consumer_args = parse_args(
                [
                    "filebus",
                ]
                + (["--back-pressure"] if back_pressure else [])
                + [
                    "--sleep-interval=0.1",
                    "--filename",
                    data_file.name,
                    "consumer",
                ]
            )
            pr, pw = os.pipe()
            consumer_proc = multiprocessing.Process(
                target=self._subprocess, args=(producer_args, pr, pw)
            )
            consumer_proc.start()
            os.close(pr)
            os.write(pw, input_string)
            os.close(pw)

            pr, pw = os.pipe()
            producer_proc = multiprocessing.Process(
                target=self._subprocess, args=(consumer_args, pr, pw)
            )
            producer_proc.start()
            os.close(pw)

            loop = asyncio.get_event_loop()
            consumer_reader = loop.create_future()
            loop.add_reader(
                pr,
                lambda: consumer_reader.done() or consumer_reader.set_result(None),
            )
            try:
                await consumer_reader
            finally:
                if not loop.is_closed():
                    loop.remove_reader(pr)
            result = os.read(pr, len(input_string))
            os.close(pr)
            self.assertEqual(result, input_string)

            if back_pressure:
                self.assertEqual(False, os.path.exists(data_file.name))
                # Suppress FileNotFoundError in NamedTemporaryFile finalizer.
                with open(data_file.name, "wb"):
                    pass

            producer_proc.terminate()
            consumer_proc.terminate()

            await asyncio.wait(
                [self.join_proc(producer_proc), self.join_proc(consumer_proc)]
            )

    async def join_proc(self, proc):
        loop = asyncio.get_event_loop()
        sentinel_reader = loop.create_future()
        loop.add_reader(
            proc.sentinel,
            lambda: sentinel_reader.done() or sentinel_reader.set_result(None),
        )
        try:
            await sentinel_reader
        finally:
            try:
                loop.remove_reader(proc.sentinel)
            except ValueError:
                pass

        # Now that proc.sentinel is ready, poll until process exit
        # status has become available.
        while True:
            proc.join(0)
            if proc.exitcode is not None:
                break
            await asyncio.sleep(0.1)

    def _subprocess(self, args, pr, pw):
        # Force instantiation of a new event loop policy as a workaround
        # for https://bugs.python.org/issue22087.
        asyncio.set_event_loop_policy(None)
        loop = asyncio.get_event_loop()

        if args.command == "producer":
            os.close(pw)
            os.dup2(pr, sys.stdin.fileno())
            if fcntl is not None:
                fcntl.fcntl(
                    sys.stdin.fileno(), fcntl.F_SETFD, fcntl.fcntl(pr, fcntl.F_GETFD)
                )
            sys.__stdin__ = sys.stdin
        else:
            os.close(pr)
            os.dup2(pw, sys.stdout.fileno())
            if fcntl is not None:
                fcntl.fcntl(
                    sys.stdout.fileno(), fcntl.F_SETFD, fcntl.fcntl(pw, fcntl.F_GETFD)
                )
            sys.__stdout__ = sys.stdout
        try:
            with FileBus(args) as bus:
                loop.run_until_complete(bus.io_loop())
        except KeyboardInterrupt:
            loop.stop()
        finally:
            loop.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
