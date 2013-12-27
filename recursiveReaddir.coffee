# taken from http://stackoverflow.com/a/5827895
fs = require 'fs'
module.exports = recursiveReaddir = (dir, done) ->
	results = []
	fs.readdir dir, (err, list) ->
		return done(err)	if err
		i = 0
		(next = ->
			file = list[i++]
			return done(null, results)	unless file
			file = dir + "/" + file
			fs.stat file, (err, stat) ->
				if stat and stat.isDirectory()
					recursiveReaddir file, (err, res) ->
						results = results.concat(res)
						next()
				else
					results.push file
					next()
		)()