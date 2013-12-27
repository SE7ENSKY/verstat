recursiveReaddir = require "./recursiveReaddir"
path = require 'path'
YAML = require 'yamljs'
util = require 'util'
fs = require 'fs'
async = require 'async'

reconfigExtend = (target, objs...) ->
	for obj in objs
		obj or= {}
		for own key, value of obj
			if key[0] is '-'
				delete target[key.substr 1]
			else
				if util.isArray value
					if key[0] is '+'
						_key = key.substr 1
						target[_key] = value.slice().concat target[_key] or []
					else if key[key.length - 1] is '+'
						_key = key.substr 0, key.length - 1
						target[_key] = (target[_key] or []).concat value.slice()
					else if key[key.length - 1] is '-'
						_key = key.substr 0, key.length - 1
						target[_key].splice target[_key].indexOf(_v), 1 if _v in target[_key] for _v in value
					else
						target[key] = value
				else if typeof value is 'object'
					reconfigExtend target, value
				else
					target[key] = value
	target

module.exports = ({root, next, expectBasename, config}) ->
	recursiveReaddir root, (err, list) ->
		root = root or process.cwd()
		expectBasename = expectBasename or "config"
		configFilePaths = []
		config = config or {}

		for filePath in list
			fileBasename = path.basename filePath
			if m = fileBasename.match ///^\.(.+)\.(json|js|coffee|yml|yaml)$///
				configFilePaths.push filePath if m[1] is expectBasename

		async.eachSeries configFilePaths, (configFilePath, doneConfigFilePath) ->
			extname = path.extname configFilePath
			switch extname
				when '.yml', '.yaml', '.json'
					fs.readFile configFilePath, encoding: 'utf8', (err, data) ->
						if err then doneConfigFilePath err else
							try
								parsed = switch extname
									when '.yml', '.yaml'
										YAML.parse data
									when '.json'
										JSON.parse data
								reconfigExtend config, parsed
								doneConfigFilePath()
							catch e
								doneConfigFilePath e
				when '.coffee', '.js'
					try
						parsed = require configFilePath
						reconfigExtend config, parsed
						doneConfigFilePath()
					catch e
						cb e
		, (err) =>
			next? err, config if next