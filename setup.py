import os
import shutil
import subprocess
import sys

from setuptools import (
    Command,
    setup,
)

sys.path.insert(0, "lib")
from filebus import (
    __author__,
    __description__,
    __email__,
    __project__,
    __version__,
)

sys.path.remove("lib")


class PyTest(Command):
    user_options = [
        ("match=", "k", "Run only tests that match the provided expressions")
    ]

    def initialize_options(self):
        self.match = None

    def finalize_options(self):
        pass

    def run(self):
        testpath = "./test"
        os.environ["EPYTHON"] = "python{}.{}".format(
            sys.version_info.major, sys.version_info.minor
        )
        pythonpath = list(filter(None, os.environ.get("PYTHONPATH", "").split(":")))
        pythonpath.insert(
            0, os.path.join(os.path.abspath(os.path.dirname(testpath)), "lib")
        )
        os.environ["PYTHONPATH"] = ":".join(pythonpath)
        pytest_exe = shutil.which("py.test")
        if pytest_exe is not None:
            test_cmd = (
                [
                    pytest_exe,
                    "-s",
                    "-v",
                    testpath,
                    "--cov-report=xml",
                    "--cov-report=term-missing",
                ]
                + (["-k", self.match] if self.match else [])
                + ["--cov=filebus"]
            )
        else:
            test_cmd = ["python", "test/test_filebus.py"]
        subprocess.check_call(test_cmd)


setup(
    name=__project__,
    version=__version__,
    description=__description__,
    author=__author__,
    author_email=__email__,
    cmdclass={"test": PyTest},
    install_requires=["filelock"],
    package_dir={"": "lib"},
    py_modules=["filebus"],
    entry_points={
        "console_scripts": "filebus = filebus:main",
    },
    python_requires=">=3.6",
)
