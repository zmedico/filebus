import os
import shutil
import subprocess
import sys

from setuptools import (
    Command,
    setup,
)

sys.path.insert(0, "lib/python")
from filebus import (
    __author__,
    __classifiers__,
    __description__,
    __email__,
    __project__,
    __project_urls__,
    __url__,
    __version__,
)

sys.path.remove("lib/python")


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


def prefix_data_files(locations):
    for dest_prefix, source_path in locations:
        source_path = os.path.abspath(source_path)

        for root, dirs, files in os.walk(source_path):
            root_offset = root[len(source_path) :].lstrip("/")
            dest_path = os.path.join(dest_prefix, root_offset)

            abs_files = []
            for x in files:
                if not x.endswith(".bash"):
                    continue
                x = os.path.join(root, x)
                abs_files.append(x)
                with open(x, "rt") as f:
                    content = f.read()
                    if "VERSION" in content:
                        content = content.replace("VERSION", __version__)
                        with open(x, "wt") as f:
                            f.write(content)

            yield (dest_path, abs_files)


def find_packages():
    for dirpath, _dirnames, filenames in os.walk("lib/python"):
        if "__init__.py" in filenames:
            yield os.path.relpath(dirpath, "lib/python")


with open(os.path.join(os.path.dirname(__file__), "README.md"), "rt") as f:
    long_description = f.read()


setup(
    name=__project__,
    version=__version__,
    description=__description__,
    long_description=long_description,
    long_description_content_type="text/markdown",
    author=__author__,
    author_email=__email__,
    url=__url__,
    project_urls=dict(__project_urls__),
    classifiers=list(__classifiers__),
    cmdclass={
        "test": PyTest,
    },
    data_files=list(
        prefix_data_files(
            [
                ("libexec/filebus", "lib/bash"),
            ]
        )
    ),
    install_requires=["filelock"],
    package_dir={"": "lib/python"},
    packages=list(find_packages()),
    entry_points={
        "console_scripts": [
            "filebus = filebus:main",
            "pipebus = filebus:main",
        ]
    },
    python_requires=">=3.6",
)
