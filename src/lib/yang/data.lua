-- Use of this source code is governed by the Apache 2.0 license; see
-- COPYING.
module(..., package.seeall)

local parse_string = require("lib.yang.parser").parse_string
local decode_string = require("lib.yang.parser").decode_string
local schema = require("lib.yang.schema")
local util = require("lib.yang.util")
local value = require("lib.yang.value")
local ffi = require("ffi")
local ctable = require('lib.ctable')
local cltable = require('lib.cltable')

function normalize_id(id)
   return id:gsub('[^%w_]', '_')
end

-- Avoid generating lots of struct types.  Note that this function is
-- only for string type names without parameters.
local type_cache = {}
function typeof(name)
   assert(type(name) == 'string')
   if not type_cache[name] then type_cache[name] = ffi.typeof(name) end
   return type_cache[name]
end

-- If a "list" node has one key that is string-valued, we will represent
-- instances of that node as normal Lua tables where the key is the
-- table key and the value does not contain the key.
local function table_string_key(keys)
   local string_key = nil
   for k,v in pairs(keys) do
      if v.type ~= 'scalar' then return nil end
      if v.argument_type.primitive_type ~= 'string' then return nil end
      if string_key ~= nil then return nil end
      string_key = k
   end
   return string_key
end

function data_grammar_from_schema(schema)
   local function struct_ctype(members)
      local member_names = {}
      for k,v in pairs(members) do
         if not v.ctype then return nil end
         table.insert(member_names, k)
      end
      table.sort(member_names)
      local ctype = 'struct { '
      for _,k in ipairs(member_names) do
         -- Separate the array suffix off of things like "uint8_t[4]".
         local head, tail = members[k].ctype:match('^([^%[]*)(.*)$')
         ctype = ctype..head..' '..normalize_id(k)..tail..'; '
      end
      ctype = ctype..'}'
      return ctype
   end
   local function value_ctype(type)
      -- Note that not all primitive types have ctypes.
      return assert(value.types[assert(type.primitive_type)]).ctype
   end
   local handlers = {}
   local function visit(node)
      local handler = handlers[node.kind]
      if handler then return handler(node) end
      return {}
   end
   local function visit_body(node)
      local ret = {}
      for id,node in pairs(node.body) do
         for keyword,node in pairs(visit(node)) do
            assert(not ret[keyword], 'duplicate identifier: '..keyword)
            assert(not ret[normalize_id(keyword)],
                   'duplicate identifier: '..normalize_id(keyword))
            ret[keyword] = node
         end
      end
      return ret
   end
   function handlers.container(node)
      local members = visit_body(node)
      if not node.presence then return members end
      return {[node.id]={type='struct', members=members,
                         ctype=struct_ctype(members)}}
   end
   handlers['leaf-list'] = function(node)
      return {[node.id]={type='array', element_type=node.type,
                         ctype=value_ctype(node.type)}}
   end
   function handlers.list(node)
      local members=visit_body(node)
      local keys, values = {}, {}
      for k in node.key:split(' +') do keys[k] = assert(members[k]) end
      for k,v in pairs(members) do
         if not keys[k] then values[k] = v end
      end
      return {[node.id]={type='table', keys=keys, values=values,
                         string_key=table_string_key(keys),
                         key_ctype=struct_ctype(keys),
                         value_ctype=struct_ctype(values)}}
   end
   function handlers.leaf(node)
      local ctype
      if node.default or node.mandatory then ctype=value_ctype(node.type) end
      return {[node.id]={type='scalar', argument_type=node.type,
                         default=node.default, mandatory=node.mandatory,
                         ctype=ctype}}
   end
   local members = visit_body(schema)
   return {type="struct", members=members, ctype=struct_ctype(members)}
end

function rpc_grammar_from_schema(schema)
   local grammar = {}
   for _,prop in ipairs({'input', 'output'}) do
      grammar[prop] = { type="sequence", members={} }
      for k,rpc in pairs(schema.rpcs) do
         local node = rpc[prop]
         if node then
            grammar[prop].members[k] = data_grammar_from_schema(node)
         else
            grammar[prop].members[k] = {type="struct", members={}}
         end
      end
   end
   return grammar
end

function rpc_input_grammar_from_schema(schema)
   return rpc_grammar_from_schema(schema).input
end

function rpc_output_grammar_from_schema(schema)
   return rpc_grammar_from_schema(schema).output
end

local function integer_type(min, max)
   return function(str, k)
      return util.tointeger(str, k, min, max)
   end
end

-- FIXME :)
local function range_validator(range, f) return f end
local function length_validator(range, f) return f end
local function pattern_validator(range, f) return f end
local function bit_validator(range, f) return f end
local function enum_validator(range, f) return f end

local function value_parser(typ)
   local prim = typ.primitive_type
   local parse = assert(value.types[prim], prim).parse
   local function validate(val) end
   validate = range_validator(typ.range, validate)
   validate = length_validator(typ.length, validate)
   validate = pattern_validator(typ.pattern, validate)
   validate = bit_validator(typ.bit, validate)
   validate = enum_validator(typ.enums, validate)
   -- TODO: union, require-instance.
   return function(str, k)
      local val = parse(str, k)
      validate(val)
      return val
   end
end

local function assert_scalar(node, keyword, opts)
   assert(node.argument or (opts and opts.allow_empty_argument),
          'missing argument for "'..keyword..'"')
   assert(not node.statements, 'unexpected sub-parameters for "'..keyword..'"')
end

local function assert_compound(node, keyword)
   assert(not node.argument, 'argument unexpected for "'..keyword..'"')
   assert(node.statements,
          'missing brace-delimited sub-parameters for "'..keyword..'"')
end

local function assert_not_duplicate(out, keyword)
   assert(not out, 'duplicate parameter: '..keyword)
end

local function struct_parser(keyword, members, ctype)
   local function init() return nil end
   local function parse1(node)
      assert_compound(node, keyword)
      local ret = {}
      for k,sub in pairs(members) do ret[normalize_id(k)] = sub.init() end
      for _,node in ipairs(node.statements) do
         local sub = assert(members[node.keyword],
                            'unrecognized parameter: '..node.keyword)
         local id = normalize_id(node.keyword)
         ret[id] = sub.parse(node, ret[id])
      end
      for k,sub in pairs(members) do
         local id = normalize_id(k)
         ret[id] = sub.finish(ret[id])
      end
      return ret
   end
   local function parse(node, out)
      assert_not_duplicate(out, keyword)
      return parse1(node)
   end
   local struct_t = ctype and typeof(ctype)
   local function finish(out)
      -- FIXME check mandatory values.
      if struct_t then return struct_t(out) else return out end
   end
   return {init=init, parse=parse, finish=finish}
end

local function array_parser(keyword, element_type, ctype)
   local function init() return {} end
   local parsev = value_parser(element_type)
   local function parse1(node)
      assert_scalar(node, keyword)
      return parsev(node.argument, keyword)
   end
   local function parse(node, out)
      table.insert(out, parse1(node))
      return out
   end
   local elt_t = ctype and typeof(ctype)
   local array_t = ctype and ffi.typeof('$[?]', elt_t)
   local function finish(out)
      -- FIXME check min-elements
      if array_t then
         out = util.ffi_array(array_t(#out, out), elt_t)
      end
      return out
   end
   return {init=init, parse=parse, finish=finish}
end

local function scalar_parser(keyword, argument_type, default, mandatory)
   local function init() return nil end
   local parsev = value_parser(argument_type)
   local function parse1(node)
      assert_scalar(node, keyword, {allow_empty_argument=true})
      return parsev(node.argument, keyword)
   end
   local function parse(node, out)
      assert_not_duplicate(out, keyword)
      return parse1(node)
   end
   local function finish(out)
      if out ~= nil then return out end
      if default then return parsev(default, keyword) end
      if mandatory then error('missing scalar value: '..keyword) end
   end
   return {init=init, parse=parse, finish=finish}
end

local function ctable_builder(key_t, value_t)
   local res = ctable.new({ key_type=key_t, value_type=value_t })
   local builder = {}
   function builder:add(key, value) res:add(key, value) end
   function builder:finish() return res end
   return builder
end

local function string_keyed_table_builder(string_key)
   local res = {}
   local builder = {}
   function builder:add(key, value)
      local str = assert(key[string_key])
      assert(res[str] == nil, 'duplicate key: '..str)
      res[str] = value
   end
   function builder:finish() return res end
   return builder
end

local function cltable_builder(key_t)
   local res = cltable.new({ key_type=key_t })
   local builder = {}
   function builder:add(key, value) res[key] = value end
   function builder:finish() return res end
   return builder
end

local function ltable_builder()
   local res = {}
   local builder = {}
   function builder:add(key, value) res[key] = value end
   function builder:finish() return res end
   return builder
end

local function table_parser(keyword, keys, values, string_key, key_ctype,
                            value_ctype)
   local members = {}
   for k,v in pairs(keys) do members[k] = v end
   for k,v in pairs(values) do members[k] = v end
   local parser = struct_parser(keyword, members)
   local key_t = key_ctype and typeof(key_ctype)
   local value_t = value_ctype and typeof(value_ctype)
   local init
   if key_t and value_t then
      function init() return ctable_builder(key_t, value_t) end
   elseif string_key then
      function init() return string_keyed_table_builder(string_key) end
   elseif key_t then
      function init() return cltable_builder(key_t) end
   else
      function init() return ltable_builder() end
   end
   local function parse1(node)
      assert_compound(node, keyword)
      return parser.finish(parser.parse(node, parser.init()))
   end
   local function parse(node, assoc)
      local struct = parse1(node)
      local key, value = {}, {}
      if key_t then key = key_t() end
      if value_t then value = value_t() end
      for k,v in pairs(struct) do
         local id = normalize_id(k)
         if keys[k] then key[id] = v else value[id] = v end
      end
      assoc:add(key, value)
      return assoc
   end
   local function finish(assoc)
      return assoc:finish()
   end
   return {init=init, parse=parse, finish=finish}
end

function data_parser_from_schema(schema)
   return data_parser_from_grammar(data_grammar_from_schema(schema))
end

function data_parser_from_grammar(production)
   local handlers = {}
   local function visit1(keyword, production)
      return assert(handlers[production.type])(keyword, production)
   end
   local function visitn(productions)
      local ret = {}
      for keyword,production in pairs(productions) do
         ret[keyword] = visit1(keyword, production)
      end
      return ret
   end
   function handlers.struct(keyword, production)
      local members = visitn(production.members)
      return struct_parser(keyword, members, production.ctype)
   end
   function handlers.array(keyword, production)
      return array_parser(keyword, production.element_type, production.ctype)
   end
   function handlers.table(keyword, production)
      local keys, values = visitn(production.keys), visitn(production.values)
      return table_parser(keyword, keys, values, production.string_key,
                          production.key_ctype, production.value_ctype)
   end
   function handlers.scalar(keyword, production)
      return scalar_parser(keyword, production.argument_type,
                           production.default, production.mandatory)
   end

   local top_parsers = {}
   function top_parsers.struct(production)
      local parser = visit1('(top level)', production)
      return function(str, filename)
         local node = {statements=parse_string(str, filename)}
         return parser.finish(parser.parse(node, parser.init()))
      end
   end
   function top_parsers.sequence(production)
      local members = visitn(production.members)
      return function(str, filename)
         local ret = {}
         for _, node in ipairs(parse_string(str, filename)) do
            local sub = assert(members[node.keyword],
                               'unrecognized rpc: '..node.keyword)
            local data = sub.finish(sub.parse(node, sub.init()))
            table.insert(ret, {id=node.keyword, data=data})
         end
         return ret
      end
   end
   local function generic_top_parser(production)
      local parser = top_parsers.struct({
            type=struct, members={[production.keyword] = production}})
      return function(str, filename)
         return parser(str, filename)[production.keyword]
      end
   end
   top_parsers.array = generic_top_parser
   top_parsers.table = generic_top_parser
   function top_parsers.scalar(production)
      local parse = value_parser(production.argument_type)
      return function(str, filename)
         return parse(decode_string(str, filename))
      end
   end
   return assert(top_parsers[production.type])(production)
end

function load_data_for_schema(schema, str, filename)
   return data_parser_from_schema(schema)(str, filename)
end

function load_data_for_schema_by_name(schema_name, str, filename)
   local schema = schema.load_schema_by_name(schema_name)
   return load_data_for_schema(schema, str, filename)
end

function rpc_input_parser_from_schema(schema)
   return data_parser_from_grammar(rpc_input_grammar_from_schema(schema))
end

function rpc_output_parser_from_schema(schema)
   return data_parser_from_grammar(rpc_output_grammar_from_schema(schema))
end

local function encode_yang_string(str)
   if str:match("^[^%s;{}\"'/]*$") then return str end
   local out = {}
   table.insert(out, '"')
   for i=1,#str do
      local chr = str:sub(i,i)
      if chr == '\n' then
         table.insert(out, '\\n')
      elseif chr == '\t' then
         table.insert(out, '\\t')
      elseif chr == '"' or chr == '\\' then
         table.insert(out, '\\')
         table.insert(out, chr)
      else
         table.insert(out, chr)
      end
   end
   table.insert(out, '"')
   return table.concat(out)
end

local value_serializers = {}
local function value_serializer(typ)
   local prim = typ.primitive_type
   if value_serializers[prim] then return value_serializers[prim] end
   local tostring = assert(value.types[prim], prim).tostring
   local function serializer(val)
      return encode_yang_string(tostring(val))
   end
   value_serializers[prim] = serializer
   return serializer
end

function data_printer_from_grammar(production)
   local handlers = {}
   local function printer(keyword, production)
      return assert(handlers[production.type])(keyword, production)
   end
   local function print_string(str, file)
      file:write(encode_yang_string(str))
   end
   local function print_keyword(k, file, indent)
      file:write(indent)
      print_string(k, file)
      file:write(' ')
   end
   local function body_printer(productions, order)
      if not order then
         order = {}
         for k,_ in pairs(productions) do table.insert(order, k) end
         table.sort(order)
      end
      local printers = {}
      for keyword,production in pairs(productions) do
         printers[keyword] = printer(keyword, production)
      end
      return function(data, file, indent)
         for _,k in ipairs(order) do
            local v = data[normalize_id(k)]
            if v ~= nil then printers[k](v, file, indent) end
         end
      end
   end
   function handlers.struct(keyword, production)
      local print_body = body_printer(production.members)
      return function(data, file, indent)
         print_keyword(keyword, file, indent)
         file:write('{\n')
         print_body(data, file, indent..'  ')
         file:write(indent..'}\n')
      end
   end
   function handlers.array(keyword, production)
      local serialize = value_serializer(production.element_type)
      return function(data, file, indent)
         for _,v in ipairs(data) do
            print_keyword(keyword, file, indent)
            file:write(serialize(v))
            file:write(';\n')
         end
      end
   end
   function handlers.table(keyword, production)
      local key_order, value_order = {}, {}
      for k,_ in pairs(production.keys) do table.insert(key_order, k) end
      for k,_ in pairs(production.values) do table.insert(value_order, k) end
      table.sort(key_order)
      table.sort(value_order)
      local print_key = body_printer(production.keys, key_order)
      local print_value = body_printer(production.values, value_order)
      if production.key_ctype and production.value_ctype then
         return function(data, file, indent)
            for entry in data:iterate() do
               print_keyword(keyword, file, indent)
               file:write('{\n')
               print_key(entry.key, file, indent..'  ')
               print_value(entry.value, file, indent..'  ')
               file:write(indent..'}\n')
            end
         end
      elseif production.string_key then
         local id = normalize_id(production.string_key)
         return function(data, file, indent)
            for key, value in pairs(data) do
               print_keyword(keyword, file, indent)
               file:write('{\n')
               print_key({[id]=key}, file, indent..'  ')
               print_value(value, file, indent..'  ')
               file:write(indent..'}\n')
            end
         end
      elseif production.key_ctype then
         return function(data, file, indent)
            for key, value in cltable.pairs(data) do
               print_keyword(keyword, file, indent)
               file:write('{\n')
               print_key(key, file, indent..'  ')
               print_value(value, file, indent..'  ')
               file:write(indent..'}\n')
            end
         end
      else
         return function(data, file, indent)
            for key, value in pairs(data) do
               print_keyword(keyword, file, indent)
               file:write('{\n')
               print_key(key, file, indent..'  ')
               print_value(value, file, indent..'  ')
               file:write(indent..'}\n')
            end
         end
      end
   end
   function handlers.scalar(keyword, production)
      local serialize = value_serializer(production.argument_type)
      return function(data, file, indent)
         local str = serialize(data)
         if str ~= production.default then
            print_keyword(keyword, file, indent)
            file:write(str)
            file:write(';\n')
         end
      end
   end

   local top_printers = {}
   function top_printers.struct(production)
      local printer = body_printer(production.members)
      return function(data, file)
         printer(data, file, '')
         return file:flush()
      end
   end
   function top_printers.sequence(production)
      local printers = {}
      for k,v in pairs(production.members) do
         printers[k] = printer(k, v)
      end
      return function(data, file)
         for _,elt in ipairs(data) do
            local id = assert(elt.id)
            assert(printers[id])(elt.data, file, '')
         end
         return file:flush()
      end
   end
   local function generic_top_printer(production)
      local printer = body_printer({[production.keyword] = production})
      return function(data, file)
         printer(data, file, '')
         return file:flush()
      end
   end
   top_printers.array = generic_top_printer
   top_printers.table = generic_top_printer
   function top_printers.scalar(production)
      local serialize = value_serializer(production.argument_type)
      return function(data, file)
         file:write(serialize(data))
         return file:flush()
      end
   end
   return assert(top_printers[production.type])(production)
end

local function string_output_file()
   local file = {}
   local out = {}
   function file:write(str) table.insert(out, str) end
   function file:flush(str) return table.concat(out) end
   return file
end

function data_printer_from_schema(schema)
   return data_printer_from_grammar(data_grammar_from_schema(schema))
end

function print_data_for_schema(schema, data, file)
   return data_printer_from_schema(schema)(data, file)
end

function print_data_for_schema_by_name(schema_name, data, file)
   local schema = schema.load_schema_by_name(schema_name)
   return print_data_for_schema(schema, data, file)
end

function rpc_input_printer_from_schema(schema)
   return data_printer_from_grammar(rpc_input_grammar_from_schema(schema))
end

function rpc_output_printer_from_schema(schema)
   return data_printer_from_grammar(rpc_output_grammar_from_schema(schema))
end

function selftest()
   print('selfcheck: lib.yang.data')
   local test_schema = schema.load_schema([[module fruit {
      namespace "urn:testing:fruit";
      prefix "fruit";
      import ietf-inet-types {prefix inet; }
      grouping fruit {
         leaf name {
            type string;
            mandatory true;
         }
         leaf score {
            type uint8 { range 0..10; }
            mandatory true;
         }
         leaf tree-grown { type boolean; }
      }

      container fruit-bowl {
         presence true;
         leaf description { type string; }
         list contents { uses fruit; key name; }
      }
      leaf addr {
         description "internet of fruit";
         type inet:ipv4-address;
      }
   }]])

   local data = load_data_for_schema(test_schema, [[
     fruit-bowl {
       description 'ohai';
       contents { name foo; score 7; }
       contents { name bar; score 8; }
       contents { name baz; score 9; tree-grown true; }
     }
     addr 1.2.3.4;
   ]])
   for i =1,2 do
      assert(data.fruit_bowl.description == 'ohai')
      local contents = data.fruit_bowl.contents
      assert(contents.foo.score == 7)
      assert(contents.foo.tree_grown == nil)
      assert(contents.bar.score == 8)
      assert(contents.bar.tree_grown == nil)
      assert(contents.baz.score == 9)
      assert(contents.baz.tree_grown == true)
      assert(data.addr == util.ipv4_pton('1.2.3.4'))

      local tmp = os.tmpname()
      local file = io.open(tmp, 'w')
      print_data_for_schema(test_schema, data, file)
      file:close()
      local file = io.open(tmp, 'r')
      data = load_data_for_schema(test_schema, file:read('*a'), tmp)
      file:close()
      os.remove(tmp)
   end
   local scalar_uint32 =
      { type='scalar', argument_type={primitive_type='uint32'} }
   local parse_uint32 = data_parser_from_grammar(scalar_uint32)
   local print_uint32 = data_printer_from_grammar(scalar_uint32)
   assert(parse_uint32('1') == 1)
   assert(parse_uint32('"1"') == 1)
   assert(parse_uint32('    "1"   \n  ') == 1)
   assert(print_uint32(1, string_output_file()) == '1')
   print('selfcheck: ok')
end