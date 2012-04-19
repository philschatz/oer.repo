`==============
 What is this?
==============

This is a mock implementation of a proposed API for deriving copies in a federated OER Repository.

It also serves as an example for communicating with services that "Transform" the content to other formats (like PDF or EPUB)


==================
 Ooh, let me see!
==================

To start it up you'll need nodejs (see http://nodejs.org ) and the node package manager (npm).

To download the dependencies::

  $ npm install .

And, to start it up::

  $ node mock/bin/server.js

Optionally you can use `wkhtml2pdf` to generate a PDF by using the ``--pdfgen /path/to/wkhtml2pdf`` command line option.
