# HTML Build Tools

This repository contains the tools and setup necessary for building the [HTML Standard](https://html.spec.whatwg.org/multipage/) from its [source](https://github.com/whatwg/html-mirror).

## Setup

1. Get a copy of [wattsi](https://github.com/whatwg/wattsi) and put the resulting binary in your PATH.
1. Copy [`dfn.js`](https://resources.whatwg.org/dfn.js) into this directory.
1. Create a `.cldr-data` directory inside this repository that is the SVN checkout of http://www.unicode.org/repos/cldr/trunk/common/main/.
1. Check out [the `build-source` branch of the source repo](https://github.com/whatwg/html-mirror) into this directory (by checking out into an empty folder then moving the contents here)

Then in theory running build.sh inside this directory will generate the spec, multipage version, entities JSON file, and more.

## Output

The relevant output files will be placed in this directory. They are:

- .htaccess
- .multipage-404
- complete.html
- dfn.js
- entities.json
- fonts/*
- images/*
- index
- link-fixup.js
- multipage/*

## TODOs

- Automate CLDR data checkout as part of the build script.
- Use the existing resources.whatwg.org dfn.js instead of requiring our own copy.
- Don't require throwing everything into one directory before doing the build; instead, let the source and cldr-data be in seperate directories, and the output be put in another directory.
- Rename whatwg/html-mirror to whatwg/html and merge the `build-source` branch into master.
