import asyncio
import os
import sys
import tempfile
import unittest

try:
    import fcntl
except ImportError:
    fcntl = None

try:
    import filebus
except ImportError:
    sys.path.append(
        os.path.join(
            os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "lib/python"
        )
    )
    import filebus


try:
    asyncio_run = asyncio.run
except AttributeError:
    asyncio_run = asyncio.get_event_loop().run_until_complete

try:
    get_running_loop = asyncio.get_running_loop
except AttributeError:
    get_running_loop = asyncio.get_event_loop


class FileBusTest(unittest.TestCase):

    impl = "python"

    def test_filebus(self):
        asyncio_run(self._test_async())

    def test_filebus_blocking_read(self):
        asyncio_run(self._test_async(force_blocking_read=True))

    async def _test_async(self, back_pressure=True, force_blocking_read=False):
        data_file = tempfile.NamedTemporaryFile(delete=False).__enter__()
        try:
            if back_pressure:
                os.unlink(data_file.name)

            input_string = b"hello world\n"
            producer_args = (
                [
                    sys.executable,
                    filebus.__file__,
                    "--impl",
                    self.impl,
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

            consumer_args = (
                [
                    sys.executable,
                    filebus.__file__,
                    "--impl",
                    self.impl,
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
            consumer_proc = await self._subprocess("producer", producer_args, pr, pw)
            os.close(pr)
            os.write(pw, input_string)
            os.close(pw)

            pr, pw = os.pipe()
            producer_proc = await self._subprocess("consumer", consumer_args, pr, pw)
            os.close(pw)

            loop = get_running_loop()
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

            await consumer_proc.wait()
            await producer_proc.wait()

            if back_pressure:
                self.assertEqual(False, os.path.exists(data_file.name))
        finally:
            try:
                os.unlink(data_file.name)
            except OSError:
                pass

    async def _subprocess(self, command, args, pr, pw):
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdin=pr if command == "producer" else None,
            stdout=pw if command == "consumer" else None
        )
        return proc


class FileBusBashTest(FileBusTest):
    impl = "bash"


if __name__ == "__main__":
    unittest.main(verbosity=2)
