# HTML Build Tools

This repository contains the tools and instructions necessary for building the [HTML Standard](https://html.spec.whatwg.org/multipage/) from its [source](https://github.com/whatwg/html).

## Getting set up

Make sure you have `git` installed on your system, and you are using a Bash shell. (On Windows, `cmd.exe` will not work, but the Git Bash shell that comes with [Git for Windows](https://git-for-windows.github.io/) works nicely.)

Then, clone this ([html-build](https://github.com/whatwg/html-build)) repo:

```
git clone https://github.com/whatwg/html-build.git && cd html-build
```

You then have a decision to make as to how you want to do your builds: locally, on your computer, or using a [Docker](https://www.docker.com/) container. We suggest going the Docker route if and only if you are already comfortable with Docker.

## Building locally

### Prerequisites

To build locally, you'll need the following commands installed on your system:

- `curl`, `grep`, `perl`, `unzip`

Optionally, for faster builds, you can install [Wattsi](https://github.com/whatwg/wattsi). If you don't bother with that, the build will use [Wattsi Server](https://github.com/domenic/wattsi-server), which requires an internet connection.

### Running the build

Run the `build.sh` script from inside your `html-build` working directory, like this:

```
./build.sh
```

The first time this runs, it will ask for your input on where to clone the HTML source from, or where on your system to find it if you've already done that. If you're working to submit a pull request to [whatwg/html](https://github.com/whatwg/html), be sure to give it the URL of your fork.

### Output

After you complete the build steps above, the build will run and generate the single-page version of the spec, the multipage version, and more. If all goes well, you should very soon have all the following in your `output/` directory:

- `.htaccess`
- `404.html`
- `entities.json`
- `fonts/*`
- `images/*`
- `index`
- `link-fixup.js`
- `multipage/*`

Now you're ready to edit the `html/source` file—and after you make your changes, you can run the `build.sh` script again to see the new output.

## Building using a Docker container

The Dockerized version of the build allows you to run the build entirely inside a "container" (lightweight virtual machine). This includes tricky dependencies like a local copy of Wattsi, as well as the Apache HTTP server with a setup analogous to that of https://html.spec.whatwg.org.

To perform a Dockerized build, use the `--docker` flag:

```
./build.sh --docker
```

The first time you do this, Docker will download a bunch of stuff to set up the container properly, but subsequent runs will simply build the standard and be very fast.

After building the standard, this will launch a HTTP server that allows you to view the result at `http://localhost:8080`. (OS X and Windows users will need to use the IP address of their docker-machine VM instead of `localhost`. You can get this with the `docker-machine env` command.)

Note that due to the way Docker works, the HTML source repository must be contained in a subdirectory of the `html-build` working directory. This will happen automatically if you let `build.sh` clone for you, but if you have a preexisting clone you'll need to move it.

## A note on Git history

Your clone doesn't need the HTML standard's complete revision history just for you to build the spec and contribute patches. So, if you use `build.sh` to create the clone, we don't start you out with a clone of the history. That makes your first build finish much faster. And if later you decide you do want to clone the complete history, you can still get it, by doing this:

```
cd ./html && git fetch --unshallow
```

That said, if you really do want to *start out* with the complete history of the repo, then run the build script for the first time like this:

```
HTML_GIT_CLONE_OPTIONS="" ./build.sh
```

That will clone the complete history for you. But be warned: It'll make your first build take *dramatically* longer to finish!
