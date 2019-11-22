
class StackElement {
	static var UID = 1;
	public var id : Int;
	public var desc : String;
	public var file : String;
	public var line : Int;
	public function new(desc:String) {
		id = UID++;
		if( desc.charCodeAt(desc.length-1) == ')'.code ) {
			var p = desc.lastIndexOf('(');
			var sep = desc.lastIndexOf(':');
			if( p > 0 && sep > p ) {
				file = desc.substr(p+1,sep-p-1);
				var sline = desc.substr(sep+1,desc.length - sep - 2);
				line = Std.parseInt(sline);
				desc = desc.substr(0,p);
				desc = desc.split("$").join("");
				if( StringTools.endsWith(desc,".__constructor__") )
					desc = desc.substr(0,-15)+"new";
			}
		}
		this.desc = desc;
	}
}

class StackLink {
	static var UID = 1;
	public var id : Int;
	public var elt : StackElement;
	public var parent : StackLink;
	public var children : Map<String,StackLink> = new Map();
	public var written : Bool;
	public function new(elt) {
		id = UID++;
		this.elt = elt;
	}
	public function getChildren(elt:StackElement) {
		var c = children.get(elt.desc);
		if( c == null ) {
			c = new StackLink(elt);
			c.parent = this;
			children.set(elt.desc,c);
		}
		return c;
	}
}

class Frame {
	public var samples : Array<{ thread : Int, time : Float, stack : Array<StackElement> }> = [];
	public var startTime : Float;
	public function new() {
	}
}

class ProfileGen {

	static function makeStacks( st : Array<StackLink> ) {
		var write = [];
		for( s in st ) {
			var s = s;
			while( s != null ) {
				if( s.written ) break;
				s.written = true;
				write.push(s);
				s = s.parent;
			}
		}
		write.sort(function(s1,s2) return s1.id - s2.id);
		return [for( s in write ) {
			callFrame : s.elt.file == null ? cast {
				functionName : s.elt.desc,
				scriptId : 0,
			} : {
				functionName : s.elt.desc,
				scriptId : 1,
				url : s.elt.file.split("\\").join("/"),
				lineNumber : s.elt.line - 1,
			},
			id : s.id,
			parent : s.parent == null ? null : s.parent.id,
		}];
	}

	static function main() {
		var args = Sys.args();
		var outFile = null;
		var debug = false;

		while( args.length > 0 ) {
			var arg = args[0];
			if( arg.charCodeAt(0) != "-".code ) continue;
			args.shift();
			switch( arg ) {
			case "-debug":
				debug = true;
			case "-out":
				outFile = args.shift();
			default:
				throw "Unknown parameter "+arg;
			}
		}

		var file = args.shift();
		if( file == null ) file = "hlprofile.dump";
		if( sys.FileSystem.isDirectory(file) ) file += "/hlprofile.dump";
		if( outFile == null ) outFile = file;

		var f = sys.io.File.read(file);
		if( f.readString(4) != "PROF" ) throw "Invalid profiler file";
		var version = f.readInt32();
		var sampleCount = f.readInt32();
		var rootElt = new StackElement("(root)");
		var curFrame = new Frame();
		var frames = [curFrame];
		var fileMaps : Array<Map<Int,StackElement>> = [];
		while( true ) {
			var time = try f.readDouble() catch( e : haxe.io.Eof ) break;
			var tid = f.readInt32();
			var msgId = f.readInt32();
			if( msgId < 0 ) {
				var count = msgId & 0x7FFFFFFF;
				var stack = [];
				for( i in 0...count ) {
					var file = f.readInt32();
					if( file == -1 )
						continue;
					var line = f.readInt32();
					var elt : StackElement;
					if( file < 0 ) {
						file &= 0x7FFFFFFF;
						elt = fileMaps[file].get(line);
						if( elt == null ) throw "assert";
					} else {
						var len = f.readInt32();
						var buf = new StringBuf();
						for( i in 0...len ) buf.addChar(f.readUInt16());
						var str = buf.toString();
						elt = new StackElement(str);
						var m = fileMaps[file];
						if( m == null ) {
							m = new Map();
							fileMaps[file] = m;
						}
						m.set(line,elt);
					}
					stack[i] = elt;
				}
				curFrame.samples.push({ time : time, thread : tid, stack : stack });
			} else {
				var size = f.readInt32();
				var data = f.read(size);
				switch( msgId ) {
				case 0:
					curFrame = new Frame();
					curFrame.startTime = time;
					frames.push(curFrame);
				default:
					Sys.println("Unknown profile message #"+msgId);
				}
			}
		}

		var s0 = frames[0].samples[0];
		var tid = s0.thread;
		frames[0].startTime = s0.time;

		function timeStamp(t:Float) {
			return Std.int((t - s0.time) * 1000000) + 1;
		}

		var json : Array<Dynamic> = [
			{
    			pid : 0,
    			tid : tid,
 	 			ts : 0,
				ph : "M",
				cat : "__metadata",
				name : "thread_name",
				args : { name : "CrBrowserMain" }
			},
			{
				pid : 0,
				tid : tid,
				ts : 0,
				ph : "P",
				cat : "disabled-by-default-v8.cpu_profiler",
			    name : "Profile",
				id : "0x1",
				args: { data : { startTime : 0 } },
			},
			{
				pid : 0,
				tid : tid,
				ts : 0,
				ph : "B",
				cat : "devtools.timeline",
				name : "FunctionCall",
			},
			{
				pid : 0,
				tid : tid,
				ts : 1,
				ph : "E",
				cat : "devtools.timeline",
				name : "FunctionCall"
			}
		];
		var lastT = 0;
		var rootStack = new StackLink(rootElt);

		for( f in frames ) {
			if( f.samples.length == 0 ) continue;
			json.push({
				pid : 0,
				tid : tid,
				ts : timeStamp(f.startTime),
				ph : "B",
				cat : "devtools.timeline",
				name : "FunctionCall",
			});
			json.push({
				pid : 0,
				tid : tid,
				ts : timeStamp(f.samples[f.samples.length-1].time),
				ph : "E",
				cat : "devtools.timeline",
				name : "FunctionCall"
			});
		}
		for( f in frames ) {
			if( f.samples.length == 0 ) continue;

			var timeDeltas = [];
			var allStacks = [];
			var lines = [];

			for( s in f.samples) {
				var st = rootStack;
				var line = 0;
				for( i in 0...s.stack.length ) {
					var s = s.stack[s.stack.length - 1 - i];
					if( s == null || s.file == "?" ) continue;
					line = s.line;
					st = st.getChildren(s);
				}
				lines.push(line);
				allStacks.push(st);
				var t = Std.int((s.time - s0.time) * 1000000);
				timeDeltas.push(t - lastT);
				lastT = t;
			}
			json.push({
				pid : 0,
				tid : tid,
				ts : 0,
				ph : "P",
				cat : "disabled-by-default-v8.cpu_profiler",
				name : "ProfileChunk",
				id : "0x1",
				args : {
					data : {
						cpuProfile : {
							nodes : makeStacks(allStacks),
							samples : [for( s in allStacks ) s.id],
							//lines : lines,
						},
						timeDeltas : timeDeltas,
					}
				}
			});
		}
		sys.io.File.saveContent(outFile, debug ? haxe.Json.stringify(json,"\t") : haxe.Json.stringify(json));
	}

}