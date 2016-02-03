# HTML Quotes Generator

This directory contains the tools for generating HTML's [quotes stylesheet](https://html.spec.whatwg.org/#quotes).

## Prerequisites

Before building, make sure you have the following commands installed on your system.

- `perl`, `svn`

You'll also need to have the Perl XML::Parser module installed on your system. It's not a "core" Perl module, so you may have to install it by doing one of the following to either get it using the perl `cpan install` command, or by getting the version packaged for your OS; for example;

- `cpan install XML::Parser`
- `apt-get install libxml-parser-perl` (Ubuntu)

## Build

Run the `build.sh` script, like this:
 ```
 ./build.sh
 ```

## Input

- [CLDR data](http://www.unicode.org/repos/cldr/trunk/common/main/) (downloaded by `build.sh`)

## Output

- `cldr.inc`

Because the output is expected to change rarely, it is checked in. The top-level `build.sh` script uses this file directly.
