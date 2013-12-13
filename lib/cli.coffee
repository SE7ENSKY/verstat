
reconfig = require './reconfig'
Verstat = require './verstat'
async = require 'async'
fs = require 'fs'

DEFAULT_CONFIG =
	src: [
		'src'
	]
	out: 'out'
	plugins: [
		'node_modules'
		'plugins'
	]
	ignore: [
		///\.DS_Store$///
		///\.DS_Store$///
		///\.hg*///
		///\.git*///
	]
	noprocess: [
		///\.verstat\.(coffee|js|yaml|yml|json)$///
	]
	nowrite: [
		///\.verstat\.(coffee|js|yaml|yml|json)$///
		///\.jade$///
		///\.less$///
		///\.styl$///
		///\.coffee$///
	]
	nocopy: [
		///\.verstat\.(coffee|js|yaml|yml|json)$///
	]
	rawExtnames: [
		'.png'
		'.jpg'
		'.gif'
		'.woff'
		'.svg'
		'.ttf'
		'.eot'
	]
	processExtnames: [
		'.css'
		'.js'
		'.html'
	]

cmd = (cmd, args, done) ->
	require('child_process').spawn(cmd, args, stdio: 'inherit' ).on 'close', (code) ->
		done? null, code

initVerstat = (env, next) ->
	verstat = new Verstat env
	async.waterfall [
		(cb) ->
			reconfig
				config: DEFAULT_CONFIG
				root: process.cwd()
				expectBasename: 'verstat'
				next: cb
		(config, cb) ->
			verstat.reconfig config, cb
	], (err) ->
		next err, verstat

program = require 'commander'

program
	.version("3.8.1")
	.option("-e, --env <env>", "specify envinronment (dev|static) [dev]", "dev")
	.option("-p, --port <port>", "specify http server port [8080]", 8080)

program
	.command("install")
	.description("install plugins")
	.action ->
		program.args.pop()
		args = [ "install", "--save" ].concat ("verstat-plugin-#{plugin}" for plugin in program.args)
		cmd "npm", args

program
	.command("uninstall")
	.description("uninstall plugins")
	.action ->
		program.args.pop()
		args = [ "uninstall", "--save" ].concat ("verstat-plugin-#{plugin}" for plugin in program.args)
		cmd "npm", args

program
	.command("update")
	.description("update verstat")
	.action ->
		cmd "npm", [ "update", "-g", "verstat" ]

program
	.command("init")
	.description("init new verstat project")
	.action ->
		fs.writeFileSync "package.json", """
			{
				"name": "my-verstat-project",
				"version": "0.0.1",
				"dependencies": {
					"verstat": "~3.8.1"
				}
			}
		""", encoding: "utf8"
		fs.mkdirSync "src"
		fs.writeFileSync "src/index.html", """
			Hello world!
		""", encoding: "utf8"

program
	.command("generate")
	.description("generate whole project to out dir with env=static")
	.action ->
		async.waterfall [
			(cb) -> initVerstat "static", cb
			(verstat, cb) -> verstat.generate cb
		], (err) ->
			console.error err if err

program
	.command("inspect")
	.description("inspect files")
	.action ->
		async.waterfall [
			(cb) -> initVerstat "static", cb
			(verstat, cb) -> verstat.inspectFiles cb
		], (err) ->
			console.error err if err

program
	.command("watch")
	.description("develop with me")
	.action ->
		async.waterfall [
			(cb) -> initVerstat program.env, cb
			(verstat, cb) ->
				async.series [
					(_cb) -> verstat.generate _cb
					(_cb) -> verstat.watch _cb
				], cb
		], (err) ->
			console.error err if err

program
	.command("serve")
	.description("generate website and serve it")
	.action ->
		async.waterfall [
			(cb) -> initVerstat program.env, cb
			(verstat, cb) ->
				async.series [
					(_cb) -> verstat.generate _cb
					(_cb) -> verstat.serve program.port, _cb
				], cb
		], (err) ->
			console.error err if err

program.parse process.argv

