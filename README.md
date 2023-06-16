# HTML Build Tools

This repository contains the tools and instructions necessary for building the [HTML Standard](https://html.spec.whatwg.org/multipage/) from its [source](https://github.com/whatwg/html).

## Getting set up

Make sure you have `git` installed on your system, and you are using a Bash shell. (On Windows, `cmd.exe` will not work, but the Git Bash shell that comes with [Git for Windows](https://git-for-windows.github.io/) works nicely.)

Then, clone this ([html-build](https://github.com/whatwg/html-build)) repo:

```bash
git clone https://github.com/whatwg/html-build.git && cd html-build
```

You then have a decision to make as to how you want to do your builds: locally, on your computer, or using a [Docker](https://www.docker.com/) container. We suggest going the Docker route if and only if you are already comfortable with Docker.

## Building locally

### Prerequisites

To build locally, you'll need the following commands installed on your system:

- `curl`, `grep`, `perl`, `unzip`

Optionally, for faster builds, you can install [Wattsi](https://github.com/whatwg/wattsi). If you don't bother with that, the build will use [Wattsi Server](https://github.com/whatwg/build.whatwg.org), which requires an internet connection. If you do use a local build of Wattsi, you'll likely also want Python 3.7+ with [pipx](https://pypa.github.io/pipx/), to enable syntax highlighting of `pre` contents.

### Running the build

Run the `build.sh` script from inside your `html-build` working directory, like this:

```bash
./build.sh
```

The first time this runs, it will look up for the HTML source from a `../html` folder, if it exists. Otherwise, it may ask for your input on where to clone the HTML source from, or where on your system to find it if you've already done that. If you're working to submit a pull request to [whatwg/html](https://github.com/whatwg/html), be sure to give it the URL of your fork.

You may also set the environment variable `$HTML_SOURCE` to use a custom location for the HTML source. For example:

```bash
HTML_SOURCE=~/hacks/dhtml ./build.sh
```

## Building using a Docker container

The Dockerized version of the build allows you to run the build entirely inside a "container" (lightweight virtual machine). This includes tricky dependencies like a local copy of Wattsi and Python.

To perform a Dockerized build, use the `--docker` flag:

```bash
./build.sh --docker
```

The first time you do this, Docker will download a bunch of stuff to set up the container properly, but subsequent runs will simply build the standard and be very fast.

If you get permissions errors on Windows, you need to first [configure](https://docs.docker.com/docker-for-windows/#file-sharing) your `html-build/` and `html/` directories to be shareable with Docker.

## Output

After you complete the build steps above, the build will run and generate the single-page version of the spec, the multipage version, and more. If all goes well, you should very soon have an `output/` directory containing important files like `index.html`, `multipage/`, and `dev/`.

You can also use the `--serve` option to `build.sh` to automatically serve the results on `https://localhost:8080/` after building (as long as you Python 3.7+ installed).

Now you're ready to edit the `html/source` file—and after you make your changes, you can run the `build.sh` script again to see the new output.

## Fast local iteration

There are a number of options to disable certain parts of the build process to speed up local iteration. Run `./build.sh help` to see them all, or just use the `--fast` flag to get maximally-fast builds.

## A note on Git history

Your clone doesn't need the HTML standard's complete revision history just for you to build the spec and contribute patches. So, if you use `build.sh` to create the clone, we don't start you out with a clone of the history. That makes your first build finish much faster. And if later you decide you do want to clone the complete history, you can still get it, by doing this:

```bash
cd ./html && git fetch --unshallow
```

That said, if you really do want to *start out* with the complete history of the repo, then run the build script for the first time like this:

```bash
HTML_GIT_CLONE_OPTIONS="" ./build.sh
```

That will clone the complete history for you. But be warned: It'll make your first build take *dramatically* longer to finish!
