# Data-plane configuration

Would be nice if you could update a Snabb program's configuration
while it's running, wouldn't it?  Well never fear, `snabb config` is
here.  Provided the data-plane author enabled this feature on their
side, users can run `snabb config` commands to query state or
configuration, provide a new configuration, or incrementally update
the existing configuration of a Snabb instance.

## `snabb config`

`snabb config` is a family of Snabb commands.  Its sub-commands
include:

* [`snabb config get`](./get/README_inc): read configuration data

* [`snabb config get-state`](./get_state/README_inc): read state data

* [`snabb config load`](./load/README_inc): load a new configuration

* [`snabb config set`](./set/README_inc): incrementally update configuration

* [`snabb config add`](./add/README_inc): augment configuration, for
  example by adding a routing table entry

* [`snabb config remove`](./delete/README_inc): remove a component from
  a configuration, for example removing a routing table entry

* [`snabb config listen`](./listen/README_inc): provide an interface to
  the `snabb config` functionality over a persistent socket, to minimize
  per-operation cost

The `snabb config get` et al commands are the normal way that Snabb
users interact with Snabb applications in an ad-hoc fashion via the
command line.  `snabb config listen` is the standard way that a NETCONF
agent like Sysrepo interacts with a Snabb network function.

### Configuration model

Most `snabb config` commands are invoked in a uniform way:

```
snabb config SUBCOMMAND [-s SCHEMA-NAME] ID PATH [VALUE]
```

`snabb config` speaks a data model that is based on YANG, for minimum
impedance mismatch between NETCONF agents and Snabb applications.  The
`-s SCHEMA-NAME` option allows the caller to indicate the YANG schema
that they want to use, and for the purposes of the lwAFTR might be `-s
ietf-softwire`.

`ID` identifies the particular Snabb instance to talk to, and can be a
PID or a name.  Snabb supports the ability for an instance to acquire
a name, which is often more convenient than dealing with changing
PIDs.

`PATH` specifies a subset of the configuration tree to operate on.

Let's imagine that the configuration for the Snabb instance in
question is modelled by the following YANG schema:

```
module snabb-simple-router {
  namespace snabb:simple-router;
  prefix simple-router;

  import ietf-inet-types {prefix inet;}

  leaf active { type boolean; default true; }

  container routes {
    presence true;
    list route {
      key addr;
      leaf addr { type inet:ipv4-address; mandatory true; }
      leaf port { type uint8 { range 0..11; }; mandatory true; }
    }
  }
}
```

In this case then, we would pass `-s snabb-simple-router` to all of
our `snabb config` invocations that talk to this router.  Snabb data
planes also declare their "native schema", so if you leave off the
`-s` option, `snabb config` will ask the data plane what schema it uses.

The configuration for a Snabb instance can be expressed in a text
format that is derived from the schema.  In this case it could look
like:

```
active true;
routes {
  route { addr 1.2.3.4; port 1; }
  route { addr 2.3.4.5; port 2; }
}
```

The surface syntax of data is the same as for YANG schemas; you can
have end-of-line comments with `//`, larger comments with `/* ... */`,
and the YANG schema quoting rules for strings apply.

Note that containers like `route {}` only appear in the data syntax if
they are marked as `presence true;` in the schema.

So indeed, `snabb config get ID /`
might print out just the output given above.

Users can limit their query to a particular subtree via passing a
different `PATH`.  For example, with the same configuration, we can
query just the `active` value:

```
$ snabb config get ID /active
true
```

`PATH` is in a subset of XPath, which should be familiar to NETCONF
operators.  Note that the XPath selector operates over the data, not
the schema, so the path components should reflect the data.

A `list` is how YANG represents associations between keys and values.
To query an element of a `list` item, use an XPath selector; for
example, to get the entry for IPv4 `1.2.3.4`, do:

```
$ snabb config get ID /routes/route[addr=1.2.3.4]
route {
  addr 1.2.3.4;
  port 1;
}
```

Or to just get the port:

```
$ snabb config get ID /routes/route[addr=1.2.3.4]/port
1
```

Likewise, to change the port for `1.2.3.4`, do:

```
$ snabb config set ID /routes/route[addr=1.2.3.4]/port 7
```

Values can be large, so it's also possible to take them from `stdin`.
Do this by omitting the value:

```
$ cat /tmp/my-configuration | snabb config set ID /
```

Resetting the whole configuration is such a common operation that it
has a special command that takes a file name instead of a path:

```
$ snabb config load ID /tmp/my-configuration
```

Using `snabb config load` has the advantage that any configuration
error has a corresponding source location.

`snabb config` can also remove part of a configuration, but only on
configuration that corresponds to YANG schema `leaf` or `leaf-list`
nodes:

```
$ snabb config remove ID /routes/route[addr=1.2.3.4]
```

One can of course augment a configuration as well:

```
$ snabb config add ID /routes
route {
  addr 4.5.6.7;
  port 11;
}
```

### Machine interface

The `listen` interface will support all of these operations with a
simple JSON protocol. Each request will be one JSON object with the
following properties:

- `id`: A request identifier; a string.  Not used by `snabb config
  listen`; just a convenience for the other side.

- `verb`: The action to perform; one of `get-state`, `get`, `set`,
  `add`, or `remove`. A string.

- `path`: A path identifying the configuration or state data on which
  to operate.  A string.

- `value`: Only present for the set and add verbs, a string
  representation of the YANG instance data to set or add. The value is
  encoded as a string in the same syntax that the `snabb config set`
  accepts.

Each response from the server will also be one JSON object, with the following properties:

- `id`: The identifier corresponding to the request.  A string.

- `status`: Either ok or error.  A string.

- `value`: If the request was a `get` request and the status is `ok`,
  then the `value` property is present, containing a `Data`
  representation of the value. A string.

Error messages may have additional properties which can help diagnose
the reason for the error. These properties will be defined in the
future.

```
$ snabb config listen -s snabb-simple-router ID
{ "id": "0", "verb": "get", "path": "/routes/route[addr=1.2.3.4]/port" }
{ "id": "1", "verb": "get", "path": "/routes/route[addr=2.3.4.5]/port" }
{ "id": "0", "status": "ok", "value: "1" }
{ "id": "1}, "status": "ok", "value: "2" }
```

The above transcript indicates that requests may be pipelined: the
client to `snabb config` listen may make multiple requests without
waiting for responses. (For clarity, the first two JSON objects in the
above transcript were entered by the user, in the console in this
case; the second two are printed out by `snabb config` in response.)

The `snabb config listen` program will acquire exclusive write access
to the data plane, preventing other `snabb config` invocations from
modifying the configuration.  In this way there is no need to provide
for notifications of changes made by other configuration clients.

### Multiple schemas

Support is planned for multiple schemas.  For example the Snabb lwAFTR
uses a native YANG schema to model its configuration and state, but
operators would also like to interact with the lwAFTR using the
relevant standardized schemas.  Work here is ongoing.

## How does it work?

The Snabb instance itself should be running in *multi-process mode*,
whereby there is one main process that shepherds a number of worker
processes.  The workers perform the actual data-plane functionality,
are typically bound to reserved CPU and NUMA nodes, and have
soft-real-time constraints.  The main process however doesn't have
much to do; it just coordinates the workers.

The main process runs a special app in its engine that listens on a
UNIX socket for special remote procedure calls, translates those calls
to updates that the data plane should apply, and dispatches those
updates to the data plane in an efficient way.  See the [`apps.config`
documentation](../../apps/config/README.md) for full details.

Some data planes, like the lwAFTR, add hooks to the `set`, `add`, and
`remove` subcommands of `snabb config` to allow even more efficient
incremental updates, for example updating the binding table in place via
a custom protocol.