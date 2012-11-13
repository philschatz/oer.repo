# What is this?

This is an in-memory implementation of a proposed API for deriving copies in a federated OER Repository.

It also serves as an example for communicating with services that "Transform" the content to other formats (like PDF or EPUB)


## Ooh, let me see!

To start it up you'll need [nodejs](http://nodejs.org) and the node package manager (npm).

To download the dependencies:

    $ npm install --dev . # --dev will install the dev dependencies like doc generation and test runners

And, to start it up:

    $ node bin/server.js --debug-user # So you don't need to authenticate via OpenID

Or, to specify a port and hostname:

    $ node bin/server.js -p 3000

Then, point your browser to the admin interface at http://localhost:3000/

If you are running this on an Internet-facing webserver then you will also need to specify the OpenID Domain (`localhost` is the default) as a command-line argument.

    $ node bin/server.js -u "http://example.com:3000"

## Debugging

You can debug the server by installing node-inspector and running:

    npm install -g node-inspector # installs node-inspector
    node --debug bin/server.js &
    node-inspector &
    # Point your browser to http://localhost:8080


# Documentation

Check out the [documentation](http://philschatz.github.com/oer.repo/docs/server.html)

Or, make it yourself by running:

    $ ./node_modules/.bin/docco src/*.coffee
