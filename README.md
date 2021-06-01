# filebus

Filebus implements multicast communication channels based on regular
files.

## Motivation

Imagine a stream of binary data like `/dev/urandom` that one wishes
for programs to be able to consume in a multicast fashion. An
obvious solution would be to redirect the binary data to a log file,
and then launch a separate `tail` command for each program that needs to
consume output from the log. However, this is not sustainable because
the log size will eventually grow too large if it is unbounded.

In order to solve this problem with `filebus`, simply pipe the live
stream to a filebus producer as follows:
```
strings /dev/urandom | filebus --filename /tmp/urandom.filebus producer
```

This command causes the file `/tmp/urandom.filebus` to behave like a
multicast pipe for filebus consumers which are launched like this:
```
filebus --filename /tmp/urandom.filebus consumer
```

## Implementation details

The on-disk format is a tar file which is updated via atomic rename
while a lock is held. File locking makes it safe for multiple
producers to concurrently produce to the same stream.

## Caveats

Consumers will certainly lose chunks at high data rates, but lower data
rates should be lossless, and consumers should always be able to observe
the most recent chunk if it has not been quickly replaced by another.

Currently, only lossy multicast streams are supported. Obviously, it
would be nice to support lossless bidirectional unicast streams (with
backpressure), and that's on the TODO list.

## TODO

* Support lossless bidirectional unicast streams (with backpressure).

## Usage
```
usage: filebus [-h] [--block-size N] [--no-file-monitoring] [--filename FILE] [--sleep-interval N] [-v] {producer,consumer} ...

  filebus 0.0.4
  Multicast communication channels based on regular files

positional arguments:
  {producer,consumer}
    producer            connect producer side of stream
    consumer            connect consumer side of stream

optional arguments:
  -h, --help            show this help message and exit
  --block-size N        maximum block size in units of bytes
  --no-file-monitoring  disable filesystem event monitoring
  --filename FILE       path of the data file (the producer updates it via atomic rename)
  --sleep-interval N    check for new messages at least once every N seconds
  -v, --verbose         verbose logging (each occurence increases verbosity)
```
