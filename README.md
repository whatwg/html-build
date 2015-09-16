# HTML Build Tools

This repository contains the tools and instructions necessary for building the [HTML Standard](https://html.spec.whatwg.org/multipage/) from its [source](https://github.com/whatwg/html).

## Prerequisites

`bash`, `git`, and `zip`/`unzip` are the only tools you need to have installed to run a build with the default settings.

## Build

Building your own copy of the HTML Standard from its source requires just two simple steps:

1. Clone this ([html-build](https://github.com/whatwg/html-build)) repo:
```
    git clone https://github.com/whatwg/html-build.git && cd html-build
```

1. Run the `build.sh` script from inside your `html-build` working directory, in one of the two following ways:
  1. If you don't already have a clone of the [https://github.com/whatwg/html](https://github.com/whatwg/html) repo or another clone from which to build:
```
        ./build.sh
```
    In the case, the build script will automatically create a clone of the HTML source repo for you, and build from that.

  1. If you *do* already have a clone of the [https://github.com/whatwg/html](https://github.com/whatwg/html) repo or another clone from which to build, the specify the path (relative or absolute) to the HTML `source` file as the final argument to the build script, like this:
```
        ./build.sh /path/to/your/html/source
```
    Of course, replace `/path/to/your/html/source` with the actual path to the `source` file on your system.

By default your build will be run remotely, on our build server, and can take 90 seconds or more to complete.

Optionally, you can run the build yourself locally, by doing a [Wattsi-enabled build](#wattsi-enabled-build), as described below.

## Output

After you complete the build steps above, the build will run and generate the single-page version of the spec, the multipage version, and more. If all goes well, you should very soon have all the following in your `output/` directory:

- `.htaccess`
- `404.html`
- `entities.json`
- `fonts/*`
- `images/*`
- `index`
- `link-fixup.js`
- `multipage/*`

And then you're also ready to edit the `html/source` file—and after you make your changes, you can run the `build.sh` script again to see the new output.

## Wattsi-enabled build

Along with the default behavior of having your build be run remotely on our build server, you can also run the build locally, in your own environment.

Doing that requires three steps;

1. Install Wattsi by following the [Wattsi build instructions](https://github.com/whatwg/wattsi) (which involves installing a [Free Pascal](http://www.freepascal.org/) compiler and then compiling a `wattsi` binary from the Wattsi sources) and putting the directory for the `wattsi` binary into you system `$PATH`.

2. Make sure you have the following commands installed on your system.
```
     bash, curl, egrep, git, grep, perl, python, svn, zip/unzip
```
3. Install the Perl XML::Parser module on your system. It's not a "core" Perl module, so you may have to install it by doing one of the following to either get it using the perl `cpan install` command, or by getting the version packaged for your OS; for example;

  - `cpan install XML::parser`
  - `apt-get install libxml-parser-perl` (Ubuntu)

4. Follow the [build instructions above](#build) just as you would otherwise.

   The build script will detect that you have a `wattsi` binary installed and then will automatically run the build locally rather than on our build server.

## Options

If you allow our build script to create a clone of the HTML source for you to use (rather than building from a clone you already have), note that we don't start you out with a clone that includes the entire revision history. Omitting the revision history makes your first build finish much faster.

But if later you decide you do want to clone the complete history, you can still get it, by doing this:
```
   cd ./html && git fetch --unshallow
```
That said, if you really do want to *start out* with the complete history of the repo, then run the build script for the first time like this:
```
   HTML_GIT_CLONE_OPTIONS="" ./build.sh
```
That will clone the complete history for you. But be warned: It'll make your first build take *dramatically* longer to finish!
