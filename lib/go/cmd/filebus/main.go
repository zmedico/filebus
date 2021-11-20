package main

import (
	"fmt"
	"io/fs"
	"io/ioutil"
	"os"
	"syscall"
	"time"

	"github.com/gofrs/flock"
	"github.com/spf13/cobra"
)

const version = "0.3.2"

type FileBusConfig struct {
	BackPressure   bool          `json:"back-pressure"`
	BlockSize      int           `json:"block-size"`
	BlockingRead   bool          `json:"blocking-read"`
	Command        string        `json:"command"`
	FileMonitoring bool          `json:"file-monitoring"`
	Filename       string        `json:"filename"`
	Impl           string        `json:"impl"`
	SleepInterval  time.Duration `json:"sleep-interval"`
}

func MaybeGetBool(cmd *cobra.Command, name string) bool {
	value, err := cmd.Flags().GetBool(name)
	if err != nil {
		value = false
	}
	return value
}

func MustGetBool(cmd *cobra.Command, name string) bool {
	value, err := cmd.Flags().GetBool(name)
	check(err)
	return value
}

func MustGetDurationFromFloat32(cmd *cobra.Command, name string) time.Duration {
	floatValue, err := cmd.Flags().GetFloat32(name)
	check(err)
	value, err := time.ParseDuration(fmt.Sprintf("%.2fs", floatValue))
	check(err)
	return value
}

func MustGetInt(cmd *cobra.Command, name string) int {
	value, err := cmd.Flags().GetInt(name)
	check(err)
	return value
}

func MustGetString(cmd *cobra.Command, name string) string {
	value, err := cmd.Flags().GetString(name)
	check(err)
	return value
}

func FileBusCobraLaunchMain(cmd *cobra.Command, args []string) error {
	config := &FileBusConfig{
		MustGetBool(cmd, "back-pressure") || MustGetBool(cmd, "lossless"),
		MustGetInt(cmd, "block-size"),
		MaybeGetBool(cmd, "blocking-read"),
		cmd.CalledAs(),
		!MustGetBool(cmd, "no-file-monitoring"),
		MustGetString(cmd, "filename"),
		MustGetString(cmd, "impl"),
		MustGetDurationFromFloat32(cmd, "sleep-interval"),
	}
	return FileBusMain(config, args)
}

func FileBusCommand() *cobra.Command {

	var filebusCmd = &cobra.Command{
		Use:   "filebus [<options>] {producer,consumer}",
		Short: "A user space multicast named pipe implementation backed by a regular file",
		Args:  cobra.MaximumNArgs(1),
	}

	flags := filebusCmd.PersistentFlags()

	flags.Bool(
		"back-pressure",
		false,
		"enable lossless back pressure protocol (unconsumed chunks cause producers to block)",
	)
	flags.Int(
		"block-size",
		4096,
		"maximum block size in units of bytes",
	)
	flags.BoolP(
		"help",
		"h",
		false,
		"show usage and exit",
	)
	flags.String(
		"impl",
		"go",
		"choose an alternative filebus implementation (alternative implementations interoperate with eachother)",
	)
	flags.String(
		"implementation",
		"go",
		"choose an alternative filebus implementation (alternative implementations interoperate with eachother)",
	)
	flags.Bool(
		"lossless",
		false,
		"enable lossless back pressure protocol (unconsumed chunks cause producers to block)",
	)
	flags.Bool(
		"no-file-monitoring",
		false,
		"disable filesystem event monitoring",
	)
	flags.String(
		"filename",
		"",
		"path of the data file (the producer updates it via atomic rename)",
	)
	flags.Float32(
		"sleep-interval",
		0.1,
		"check for new messages at least once every N seconds",
	)
	flags.CountP(
		"verbose",
		"v",
		"verbose logging (each occurence increases verbosity)",
	)

	var producerCmd = &cobra.Command{
		Use:   "producer",
		Short: "connect producer side of stream",
		RunE:  FileBusCobraLaunchMain,
	}
	producerFlags := producerCmd.PersistentFlags()
	producerFlags.Bool("blocking-read", false, "blocking read from input (clear the O_NONBLOCK flag)")
	filebusCmd.AddCommand(producerCmd)

	var consumerCmd = &cobra.Command{
		Use:   "consumer",
		Short: "connect consumer side of stream",
		RunE:  FileBusCobraLaunchMain,
	}
	filebusCmd.AddCommand(consumerCmd)

	return filebusCmd
}

func main() {
	filebusCmd := FileBusCommand()
	filebusCmd.SetArgs(os.Args[1:])
	if err := filebusCmd.Execute(); err != nil {
		os.Exit(errMsg(err.Error()))
	}
}

func errMsg(msg string, a ...interface{}) int {
	fmt.Fprintf(os.Stderr, msg, a...)
	fmt.Fprintln(os.Stderr)
	return 1
}

func FileBusMain(config *FileBusConfig, args []string) error {
	var err error
	if config.Command == "producer" {
		err = FileBusProducer(config)
	} else if config.Command == "consumer" {
		err = FileBusConsumer(config)
	} else {
		panic(fmt.Sprintf("unknown command: %s", config.Command))
	}
	return err
}

func FileBusProducer(config *FileBusConfig) error {
	maybeAsyncRead := !config.BlockingRead
	if maybeAsyncRead {
		stdinSt, err := os.Stdin.Stat()
		check(err)
		stdinMode := stdinSt.Mode()
		maybeAsyncRead = stdinMode&(fs.ModeCharDevice|fs.ModeNamedPipe|fs.ModeSocket) != 0
	}
	fd := int(os.Stdin.Fd())
	readBuffer := make([]byte, config.BlockSize)
	stdinBuffer := ""
	rfds := &syscall.FdSet{}
	timeout := syscall.Timeval{}
	timeoutUsec := int64(config.SleepInterval / time.Microsecond)

	if maybeAsyncRead {
		err := syscall.SetNonblock(fd, true)
		check(err)
		FD_ZERO(rfds)
	}
	flushTime := time.Now()
	eof := false
	for !eof {
		// https://github.com/mindreframer/golang-stuff/blob/master/github.com/pebbe/zmq2/examples/udpping1.go
		timeout.Sec, timeout.Usec = timeoutUsec/1000000, timeoutUsec%1000000
		readEvent := true
		if maybeAsyncRead {
			FD_SET(rfds, fd)
			fdCount, err := syscall.Select(fd+1, rfds, nil, nil, &timeout)
			if err != nil || fdCount == 0 {
				readEvent = false
			}
		}
		if readEvent {
			n, err := os.Stdin.Read(readBuffer)
			if err != nil {
				if err.Error() != "EOF" {
					panic(err)
				}
				eof = true
			}
			if n > 0 {
				stdinBuffer += string(readBuffer[:n])
			}
		}
		if len(stdinBuffer) > 0 {
			if eof || len(stdinBuffer) >= config.BlockSize || time.Now().Sub(flushTime) >= config.SleepInterval {
				flushTime = time.Now()
				flushBuffer(config, stdinBuffer)
				stdinBuffer = ""
			}
		}
	}

	// Write the EOF buffer.
	if config.BackPressure {
		for {
			if _, err := os.Stat(config.Filename); err != nil {
				fileLock := flock.New(config.Filename + ".lock")
				err := fileLock.Lock()
				check(err)
				if _, err = os.Stat(config.Filename); err == nil {
					// Too late to report EOF.
					err = fileLock.Unlock()
					check(err)
					break
				}
				// Write an empty buffer to indicate EOF.
				f, err := os.Create(config.Filename + ".__new__")
				check(err)
				err = f.Close()
				check(err)
				err = os.Rename(config.Filename+".__new__", config.Filename)
				check(err)
				err = fileLock.Unlock()
				check(err)
				break
			} else {
				time.Sleep(config.SleepInterval)
			}
		}
	}
	return nil
}

func flushBuffer(config *FileBusConfig, stdinBuf string) {
	//fmt.Fprintf(os.Stderr, "flushed %d bytes: %v\n", len(stdinBuf), stdinBuf)
	for {
		if config.BackPressure {
			for {
				if _, err := os.Stat(config.Filename); err != nil {
					break
				}
				time.Sleep(config.SleepInterval)
			}
		}
		fileLock := flock.New(config.Filename + ".lock")
		err := fileLock.Lock()
		check(err)
		if config.BackPressure {
			if _, err = os.Stat(config.Filename); err == nil {
				err = fileLock.Unlock()
				check(err)
				continue
			}
		}
		f, err := os.Create(config.Filename + ".__new__")
		check(err)
		_, err = f.WriteString(stdinBuf)
		check(err)
		err = f.Close()
		check(err)
		err = os.Rename(config.Filename+".__new__", config.Filename)
		check(err)
		err = fileLock.Unlock()
		check(err)
		break
	}
}

func check(e error) {
	if e != nil {
		panic(e)
	}
}

func FD_SET(p *syscall.FdSet, i int) {
	p.Bits[i/64] |= 1 << uint(i) % 64
}

func FD_ZERO(p *syscall.FdSet) {
	for i := range p.Bits {
		p.Bits[i] = 0
	}
}

func FileBusConsumer(config *FileBusConfig) error {
	var previousStat *os.FileInfo
	var currentStat os.FileInfo
	var err error
	for {
		if currentStat, err = os.Stat(config.Filename); err == nil {
			if config.BackPressure {
				fileLock := flock.New(config.Filename + ".lock")
				err := fileLock.Lock()
				check(err)

				if _, err = os.Stat(config.Filename); err != nil {
					err = fileLock.Unlock()
					check(err)
					continue
				}
				content, err := ioutil.ReadFile(config.Filename)
				check(err)

				if len(content) > 0 {
					_, err := os.Stdout.Write(content)
					check(err)
				}

				// remove the file in order relieve back pressure
				err = os.Remove(config.Filename)
				check(err)

				err = fileLock.Unlock()
				check(err)

				if len(content) == 0 {
					// EOF marker for back pressure protocol
					return nil
				}
				continue
			}

			if !(previousStat != nil && os.SameFile(*previousStat, currentStat)) {
				fileLock := flock.New(config.Filename + ".lock")
				err := fileLock.Lock()
				check(err)

				if currentStat, err = os.Stat(config.Filename); err != nil {
					err = fileLock.Unlock()
					check(err)
					continue
				}

				content, err := ioutil.ReadFile(config.Filename)
				check(err)

				previousStat = &currentStat

				if len(content) > 0 {
					_, err := os.Stdout.Write(content)
					check(err)
				}

				err = fileLock.Unlock()
				check(err)
			}
		}
		time.Sleep(config.SleepInterval)
	}
	return nil
}
