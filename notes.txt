Go to http://localhost:3000/admin to see the admin console

In order to get valid xml from jsdom I had to hack it in 3 spots:
node_modules/jsdom/lib/jsdom/browser/domtohtml.js
- Set validTags = {}
- Comment out node = node._entity;

node_modules/jsdom/lib/jsdom/browser/htmlencoding.js:
- Comment the line  '\xA0': '&nbsp;
