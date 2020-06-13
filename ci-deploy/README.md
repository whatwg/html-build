# HTML Standard CI Deploy

This directory contains files used specifically for deploying the HTML Standard in CI. They are not generally relevant to local builds.

The setup is assumed to be a directory containing:

- A subdirectory `html-build` containing the contents of this entire [whatwg/html-build](https://github.com/whatwg/html-build) repository
- A subdirectory `html` containing the contents of the [whatwg/html](https://github.com/whatwg/html) repository

Then, run the `html-build/ci-deploy/outside-container.sh` script. What it does is documented via inline comments; check it out to learn more. In particular, note that several environment variables are assumed to be set, via the CI system.
