==============
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

  $ node bin/server.js

Or, to specify a port and hostname::

  $ node bin/server.js -p 3001 --pdfgen /path/to/prince

Optionally you can use `wkhtml2pdf` to generate a PDF by using the ``--pdfgen /path/to/wkhtml2pdf`` command line option.

Then, point your browser to the admin interface at http://localhost:3000/admin

If you are running this on an Internet-facing webserver then you will also need to specify the OpenID Domain (localhost is the default) as a command-line argument.

  $ node bin/server -u "http://example.com:3000" 

