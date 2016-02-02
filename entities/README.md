# HTML Entities Generator

This directory contains the tools for generating HTML's [named character references](https://html.spec.whatwg.org/#named-character-references).

## Prerequisites

Before building, make sure you have the following commands installed on your system.

- `curl`, `perl`, `python`

## Build

Run the `build.sh` script, like this:
 ```
 ./build.sh
 ```

## Input

- `entities-legacy.inc`
- `json-entities-legacy.inc`
- [`unicode.xml`](https://github.com/w3c/xml-entities/blob/gh-pages/unicode.xml) (downloaded by `build.sh`)

## Output

- `entities-dtd.url`
- `entities.inc`
- `entities.json`

Because the output is expected to change very rarely, if ever, it is checked in. The top-level `build.sh` script uses these files directly.
