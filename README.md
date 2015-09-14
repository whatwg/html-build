# HTML Build Tools

This repository contains the tools and instructions necessary for building the [HTML Standard](https://html.spec.whatwg.org/multipage/) from its [source](https://github.com/whatwg/html).

## Prerequisites

Before building, make sure you have the following commands installed on your system.

- `curl`, `egrep`, `git`, `grep`, `perl`, `python`, `svn`, `unzip`

You'll also need to have the Perl XML::Parser module installed on your system. It's not a "core" Perl module, so you may have to install it by doing one of the following to either get it using the perl `cpan install` command, or by getting the version packaged for your OS; for example;

- `cpan install XML::parser`
- `apt-get install libxml-parser-perl` (Ubuntu)

## Build

Building your own copy of the HTML Standard from its source requires just two simple steps:

1. Clone this ([html-build](https://github.com/whatwg/html-build)) repo:
```
    git clone https://github.com/whatwg/html-build.git && cd html-build
```

1. Run the `build.sh` script from inside your `html-build` working directory, like this:
```
    ./build.sh
```

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

## Options

Your clone doesn't need the HTML standard's complete revision history just for you to build the spec and contribute patches. So, by default we don't start you out with a clone of the history. That makes your first build finish much faster. And if later you decide you do want to clone the complete history, you can still get it, by doing this:
```
   cd ./html && git fetch --unshallow
```
That said, if you really do want to *start out* with the complete history of the repo, then run the build script for the first time like this:
```
   HTML_GIT_CLONE_OPTIONS="" ./build.sh
```
That will clone the complete history for you. But be warned: It'll make your first build take *dramatically* longer to finish!
