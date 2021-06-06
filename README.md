# filebus

A userspace multicast named pipe implementation, backed by a regular
file, and accessed via a filebus stdio stream.

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

The on-disk file is updated via atomic rename while a lock is held.
File locking makes it safe for multiple producers to concurrently
produce to the same stream.

The filebus `--back-pressure` protocol uses deleted files to indicate
consumed buffers. File locking ensures that exactly one
consumer will consume and delete each buffer, and producers will
not attempt to write a new buffer until the previous buffer has been
consumed. A producer writes an empty buffer in order to indicate
EOF, and a consumer will terminate when it reads the empty buffer.

## Caveats

The `--back-pressure` option implement a lossless protocol, but this
protocol causes only a single consumer to receive a given buffer.
However, it is possible for an unlimited number of consumers which
are not using the `--back-pressure` option to eavesdrop on this stream
(provided they have been granted file read permission at the OS level),
albeit in a lossy manner.

In the absence of the `--back-pressure` option, consumers will
certainly lose chunks at high data rates, but lower data rates should
be lossless, and consumers should always be able to observe the most
recent chunk if it has not been quickly replaced by another.

## Alternative implementations

The bash implementation currently currently reads newline delimited
chunks, whereas the python implementation uses the `--sleep-interval`
and `--block-size` arguments to delimit chunks. The python
implementation is agnostic to the underlying stream in the sense that
it explicitly does not interpret any stream content as a delimiter,
which is a desirable property for filebus, but not essential for many
use cases.

## Usage
```
usage: filebus [-h] [--back-pressure] [--block-size N]
               [--impl {bash,python}] [--lossless] [--no-file-monitoring]
               [--filename FILE] [--sleep-interval N] [-v]
               {producer,consumer} ...

  filebus 0.2.0
  A user space multicast named pipe implementation backed by a regular file

positional arguments:
  {producer,consumer}
    producer            connect producer side of stream
    consumer            connect consumer side of stream

optional arguments:
  -h, --help            show this help message and exit
  --back-pressure       enable lossless back pressure protocol (unconsumed
                        chunks cause producers to block)
  --block-size N        maximum block size in units of bytes
  --impl {bash,python}, --implementation {bash,python}
                        choose an alternative filebus implementation
                        (alternative implementations interoperate with
                        eachother)
  --lossless            an alias for --back-pressure
  --no-file-monitoring  disable filesystem event monitoring
  --filename FILE       path of the data file (the producer updates it via
                        atomic rename)
  --sleep-interval N    check for new messages at least once every N
                        seconds
  -v, --verbose         verbose logging (each occurence increases
                        verbosity)
```
