EventEmitter = require('events').EventEmitter
fs = require "fs"
path = require "path"
mkdirp = require "mkdirp"
async = require "async"
rimraf = require "rimraf"
_ = require "lodash"
YAML = require "yamljs"
QueryEngine = require "query-engine"
reconfig = require "./reconfig"
recursiveReaddir = require "./recursiveReaddir"

FILE_THREADS = 4

module.exports = class Verstat extends EventEmitter
	constructor: (@env) ->
		super
		@config = {}
		@processors = {}
		@preprocessors = {}
		@postprocessors = {}
		@files = QueryEngine.createCollection []
		@plugins = {}
		@nextFileId = 1
		@log "DEBUG", "instantiated verstat with env #{@env}"

		@on "templateData", (file, templateData) =>
			templateData = _.extend templateData, _.omit file, ['source', 'processed', 'fn', 'dependencies', 'dependants', 'read', 'process', 'write']
			templateData.env = @env
			templateData.queryFiles = (q) =>
				found = @queryFiles q
				@depends file, found if found
				found
			templateData.queryFile = (q) =>
				found = @queryFile q
				@depends file, found if found
				found

	setEnv: (@env) ->
		@log "DEBUG", "env set to #{@env}"

	extendProgram: (program) ->
		program
			.command("generate")
			.description("generate whole project to out dir with env=static")
			.action =>
				@setEnv "static"
				async.series [
					(cb) => @configure cb
					(cb) => @generate cb
				], (err) =>
					@log "ERROR", err if err

		program
			.option("-p, --port <port>", "specify http server port [8080]", 8080)
		program
			.command("serve")
			.description("generate website and serve it")
			.action =>
				async.series [
					(cb) => @configure cb
					(cb) => @generate cb
					(cb) => @serve program.port, cb
				], (err) =>
					@log "ERROR", err if err

	queryFile: (q) =>
		found = @files.findOne(q)
		if found
			found = found.toJSON()
			found
		else
			null
	queryFiles: (q) =>
		found = @files.findAll(q)
		if found
			found = found.toJSON()
			found
		else
			null

	modified: (file) ->
		@files.remove file.id
		@files.add file

	log: (level, objs...) ->
		level = level.toUpperCase()
		switch level
			when 'WARN', 'ERROR', 'FATAL'
				console.error level, objs...
			when 'INFO'
				console.log level, objs...
			when 'DEBUG', 'TRACE'
				console.log level, objs...

	generate: (next) ->
		if @config.out
			async.series [
				(cb) => rimraf @config.out, cb
				(cb) => @initPlugins cb
				(cb) => @buildFiles cb
				(cb) => @regenerate null, cb
			], next
		else
			next new Error "out must be configured"

	regenerate: (fileIds, next) ->
		if @config.out
			async.series [
				(cb) => @readFiles cb, fileIds
				(cb) => @preprocessFiles cb, fileIds
				(cb) => @processFiles cb, fileIds
				(cb) => @postprocessFiles cb, fileIds
				(cb) => @writeFiles cb, fileIds
				(cb) => @copyFiles cb, fileIds
			], next
		else
			next new Error "out must be configured"

	resolveAllDependants: (file, excludeIds = []) ->
		result = file.dependants
		dependants = @queryFiles id: $in: _.without(file.dependants, excludeIds...)
		excludeIds.push f.id for f in dependants
		if dependants
			for dependant in dependants
				result = result.concat @resolveAllDependants dependant, excludeIds
		result

	configure: (next) ->
		@log "DEBUG", "configure"
		reconfig
			config: require './defaults'
			root: process.cwd()
			expectBasename: 'verstat'
			next: (err, config) =>
				if err then next err
				else @reconfig config, next

	reconfig: (newConfig, next) ->
		@config = newConfig
		@log "DEBUG", "reconfig", newConfig
		next()

	initPlugins: (next) ->
		@log "INFO", "initPlugins", @config.plugins
		async.each @config.plugins, (pluginsPath, donePluginsPath) =>
			@log "DEBUG", "initPlugins pluginsPath", pluginsPath
			fs.exists pluginsPath, (exists) =>
				if exists
					async.waterfall [
						(cb) => recursiveReaddir pluginsPath, cb
						(filePathList, cb) =>
							filePathList = filePathList.filter (f) ->
								f and f.match ///\.verstatplugin\.(coffee|js)///
							async.each filePathList, (filePath, doneFilePath) =>
								@initPlugin path.resolve(filePath), doneFilePath
							, cb
					], (err) =>
						donePluginsPath err
				else
					donePluginsPath()
		, next

	initPlugin: (pluginPath, next) ->
		@log "DEBUG", "initPlugin", pluginPath
		try
			plugin = require pluginPath
			plugin.bind(@) (err, data) =>
				if err then next err else
					@plugins[pluginPath] = data
					next null
		catch err
			next err

	processor: (name, processorConfig) ->
		@processors[name] = processorConfig
	preprocessor: (name, preprocessorConfig) ->
		@preprocessors[name] = preprocessorConfig
	postprocessor: (name, postprocessorConfig) ->
		@postprocessors[name] = postprocessorConfig

	buildFiles: (next) ->
		@log "INFO", "buildFiles", @config.src
		allFiles = []
		srcPathList = @config.src
		srcPathList = [ srcPathList ] if not _.isArray srcPathList
		async.each srcPathList, (srcPath, doneSrc) =>
			@log "DEBUG", "buildFiles srcPath", srcPath
			recursiveReaddir srcPath, (err, filePathList) =>
				if err then doneSrc err else
					allFiles = allFiles.concat filePathList
					doneSrc()
		, (err) =>
			if err then next err else
				allFiles = @filterIgnores allFiles
				async.each allFiles, (filePath, doneFilePath) =>
					@buildFile filePath, doneFilePath
				, next

	filterIgnores: (files) ->
		@applyFilters files, @config.ignore

	isNoProcess: (filePath) ->
		@applyFilters([ filePath ], @config.noprocess).length is 0
	isNoWrite: (filePath) ->
		@applyFilters([ filePath ], @config.nowrite).length is 0
	isNoCopy: (filePath) ->
		@applyFilters([ filePath ], @config.nocopy).length is 0

	applyFilters: (files, filters) ->
		return files unless filters
		filtered = files.slice()
		for file in files
			for filter in filters
				if _.isString filter
					filtered.splice filtered.indexOf(file), 1 if file is filter
				else if _.isFunction filter
					filtered.splice filtered.indexOf(file), 1 if filter file
				else if _.isRegExp filter
					filtered.splice filtered.indexOf(file), 1 if filter.test file
		filtered

	readFiles: (next, fileIds) ->
		@log "INFO", "readFiles", fileIds
		filter =
			read: on
		filter.id = $in: fileIds if fileIds
		async.eachLimit @files.findAll(filter).toJSON(), FILE_THREADS, (file, doneFile) =>
			@readFile file, doneFile
		, next

	preprocessFiles: (next, fileIds) ->
		@log "INFO", "preprocessFiles", fileIds
		filter = {}
		filter.id = $in: fileIds if fileIds
		async.each @files.findAll(filter).toJSON(), (file, doneFile) =>
			@preprocessFile file, doneFile
		, next

	processFiles: (next, fileIds) ->
		@log "INFO", "processFiles", fileIds
		filter =
			process: on
			processor: $ne: null
		filter.id = $in: fileIds if fileIds
		async.each @files.findAll(filter).toJSON(), (file, doneFile) =>
			if @isNoProcess file.srcFilename then doneFile()
			else @processFile file, doneFile
		, next

	postprocessFiles: (next, fileIds) ->
		@log "INFO", "postprocessFiles", fileIds
		filter = {}
		filter.id = $in: fileIds if fileIds
		async.each @files.findAll(filter).toJSON(), (file, doneFile) =>
			@postprocessFile file, doneFile
		, next

	writeFiles: (next, fileIds) ->
		@log "INFO", "writeFiles", fileIds
		filter =
			write: on
		filter.id = $in: fileIds if fileIds
		async.eachLimit @files.findAll(filter).toJSON(), FILE_THREADS, (file, doneFile) =>
			if @isNoWrite file.filename then doneFile()
			else @writeFile file, doneFile
		, next

	copyFiles: (next, fileIds) ->
		@log "INFO", "copyFiles", fileIds
		filter =
			raw: yes
		filter.id = $in: fileIds if fileIds
		async.eachLimit @files.findAll(filter).toJSON(), FILE_THREADS, (file, doneFile) =>
			if @isNoCopy file.filename then doneFile()
			else @copyFile file, doneFile
		, next

	resolveProcessor: (srcFilename) ->
		for name, processor of @processors
			return name if processor.srcExtname and processor.srcExtname is path.extname srcFilename
		return null
	resolveSrcPath: (filePath) ->
		if _.isArray @config.src
			for srcPath in @config.src
				return srcPath if filePath.indexOf(srcPath) is 0
		else
			return @config.src if filePath.indexOf(@config.src) is 0
		return null

	buildFile: (filePath, next) ->
		@log "DEBUG", "buildFile", filePath
		try
			srcPath = @resolveSrcPath filePath
			srcFilename = path.relative srcPath, filePath
			processor = @resolveProcessor srcFilename
			dir = path.dirname srcFilename
			dir = '' if dir is '.'
			filename = if processor
				processorConfig = @processors[processor]
				(if dir then dir + path.sep else '') + path.basename(srcFilename, processorConfig.srcExtname) + processorConfig.extname
			else
				srcFilename

			basename = path.basename filename
			extname = path.extname filename
			shortname = path.basename basename, extname
			fullname = (if dir then dir + path.sep else '') + shortname

			process = processor isnt null or extname in @config.processExtnames
			raw = processor is null and extname in @config.rawExtnames
			process = no if @isNoProcess srcFilename

			@files.add file =
				id: @nextFileId++
				srcFilePath: filePath
				srcFilename: srcFilename
				srcExtname: path.extname srcFilename
				filename: filename
				dir: dir
				basename: basename
				extname: extname
				shortname: shortname
				fullname: fullname
				url: '/' + fullname
				processor: processor
				read: not raw
				process: process
				write: not raw
				raw: raw
				dependants: []
				dependencies: []

			next null, file
		catch err
			next err

	splitSourceAndMeta: (file, data, next) ->
		pushdata = (d) =>
			if _.isArray d
				_.extend file, items: d
			else
				_.extend file, d

		@log "DEBUG", "splitSourceAndMeta", file.id, file.srcFilePath
		switch file.srcExtname
			when ".jade"
				if data.match ///^//---\n///
					lines = data.split "\n"
					lines.splice 0, 1 # drop //---
					metaString = []
					while m = lines[0].match ///^\t(.*)$///
						metaString += m[1] + "\n"
						lines.splice 0, 1
					file.source = lines.join "\n"
					try
						pushdata YAML.parse metaString.replace ///\t///g, '  '
						next()
					catch e
						next e
				else
					file.source = data
					next()
			when ".json"
				file.source = data
				try
					pushdata JSON.parse data
					next()
				catch e
					next e
			when ".yaml", ".yml"
				file.source = data
				try
					pushdata YAML.parse data.replace ///\t///g, '  '
					next()
				catch e
					next e
			else
				if m = data.match ///^---\n///
					lines = data.split "\n"
					lines.splice 0, 1 # drop first ---
					metaString = []
					while lines[0] isnt '---'
						metaString += lines[0] + "\n"
						lines.splice 0, 1
					lines.splice 0, 1 # drop last ---

					file.source = lines.join "\n"
					try
						pushdata YAML.parse metaString.replace ///\t///g, '  '
						next()
					catch e
						next e
				else
					file.source = data
					next()

	readFile: (file, next) ->
		@log "DEBUG", "readFile", file.srcFilePath
		fs.readFile file.srcFilePath, encoding: 'utf8', (err, data) =>
			if err then next err else
				@splitSourceAndMeta file, data, (err) =>
					@modified file
					if err then next err else
						@emit "readFile", file
						next null, file

	preprocessFile: (file, next) ->
		preprocessors = _.filter @preprocessors, (c) ->
			_.has(c, 'extname') and file.extname is c.extname or _.has(c, 'srcExtname') and file.srcExtname is c.srcExtname or not _.has(c, 'extname') and not _.has(c, 'srcExtname')
		preprocessors = _.sortBy preprocessors, 'priority'

		async.eachSeries preprocessors, (preprocessor, nextPreprocessor) =>
			preprocessor.preprocess file, nextPreprocessor
		, next

	postprocessFile: (file, next) ->
		postprocessors = _.sortBy _.filter @postprocessors, (c, name) ->
			_.has(c, 'extname') and file.extname is c.extname or _.has(c, 'srcExtname') and file.srcExtname is c.srcExtname or not _.has(c, 'extname') and not _.has(c, 'srcExtname')
		postprocessors = _.sortBy postprocessors, 'priority'

		async.eachSeries postprocessors, (postprocessor, nextPostprocessor) =>
			postprocessor.postprocess file, nextPostprocessor
		, next
	
	processFile: (file, next) ->
		@log "DEBUG", "processFile", file.srcFilePath, file.processor
		processor = @processors[file.processor]
		compilerOpts = {}
		processor.compile file, compilerOpts, (err, output) =>
			if err then next err else
				if file.layout
					layoutFile = @files.findOne(fullname: file.layout).toJSON()
					if layoutFile and layoutFile.fn
						data = {}
						@emit 'templateData', layoutFile, data
						data.file = file
						data.content = output
						file.processed = layoutFile.fn data
						@depends file, [ layoutFile ]
						# @modified file # called by @depends
						@emit "processFile", file
						next null, file
					else
						next new Error "layout #{file.layout} not found"
				else
					file.processed = output
					@modified file
					@emit "processFile", file
					next null, file

	writeFile: (file, next) ->
		@log "DEBUG", "writeFile", file.srcFilePath, file.filename
		mkdirp path.dirname("#{@config.out}/#{file.filename}"), (err) =>
			if err
				@log "ERROR", "error creating directories", err
			else
				data = if file.processor then file.processed else file.source
				fs.writeFile "#{@config.out}/#{file.filename}", data, encoding: 'utf8', (err) =>
					if err then next err else
						@emit "writeFile", file
						next()

	copyFile: (file, next) ->
		@log "DEBUG", "copyFile", file.filename
		mkdirp path.dirname("#{@config.out}/#{file.filename}"), (err) =>
			return next err if err
			cbCalled = no
			onErr = (err) =>
				@log "ERROR", "file copy error", err
				unless cbCalled
					cbCalled = yes
					next err
			rd = fs.createReadStream file.srcFilePath
			rd.on "error", onErr
			wr = fs.createWriteStream "#{@config.out}/#{file.filename}"
			wr.on "error", onErr
			wr.on "close", =>
				unless cbCalled
					@emit "copyFile", file
					next()
			rd.pipe wr

	removeFile: (file, next) ->
		@log "DEBUG", "removeFile", file.filename
		async.series [
			(cb) =>
				if file.raw or file.write
					fs.unlink "#{@config.out}/#{file.filename}", cb
				else cb()
			(cb) =>
				@files.remove file.id
				@emit "removeFile", file
				cb()
		], next

	depends: (file, dependencies) ->
		dependencies = [ dependencies ] if not _.isArray dependencies
		for dependency in dependencies
			file.dependencies.push dependency.id if dependency.id not in file.dependencies
			dependency.dependants.push file.id if file.id not in dependency.dependants
			@modified dependency
		@modified file

	serve: (port, next) ->
		express = require 'express'
		app = express()
		app.set "port", port
		app.use express.logger @env
		app.use express.static @config.out
		app.use express.errorHandler()
		
		http = require 'http'
		server = http.createServer app
		server.listen app.get('port'), =>
			@log "INFO", "server started on port #{port}"
			@emit "serve", app, server
			next()
