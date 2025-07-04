# icu-zig

`icu-zig` is a Zig package for a compilation of
[ICU4C](https://icu.unicode.org/) version 77.1.

My goal for this project is to not rely on anything hacky or non-standard; the
way `icu-zig` builds the ICU libraries _closely follows_ the way that the ICU
project builds them using Makefiles. The results are **clean**, **configurable**
compilations of the ICU libraries.

## Caveats

`icu-zig` is currently untested on Linux and Windows platforms. While no
platform-specific code exists within the build file itself, it is still possible
that compilation errors occur on those platforms.

It is my goal for `icu-zig` to work on all platforms, so make sure to submit an
issue or PR if that is not the case!

## Usage

Add this to your `build.zig.zon`:

```zig
.dependencies = .{
    .icu = .{
        .url = "https://github.com/dzfrias/icu-zig/archive/refs/heads/main.tar.gz",
        // The correct hash will be suggested after a compilation attempt
    }
}
```

Then, modify your `build.zig` to contain the following:

```zig
const icu = b.dependency(
    "icu",
    .{
        .target = target,
        .optimize = optimize,
        // Build options go here
    },
);
exe.linkLibrary(icu.artifact("icuuc"));
exe.linkLibrary(icu.artifact("icudata"));
// Link the other libraries you need
```

This will link `libicuuc` and `libicudata`, and they will then be usable in
source files using `@cImport`. For example:

```zig
const c = @cImport({
    @cInclude("unicode/ucnv.h");
});
```

## Build Options

`icu-zig` supports build options to customize the final ICU libraries.

| Name               | Description                                                  |
| ------------------ | ------------------------------------------------------------ |
| `icudata-removals` | Specifies data items to remove from the `libicudata` library |

### Data Item Removals

The ICU data library `libicudata` is around 30MB large by default. It includes a
lot of information, such as:

- Timezone conversions
- Locale information,
- Charset conversions
- Collation data
- ...and more!

If you're not using all that data for your project, consider using the
`icudata-removals` option. This option allows you to remove data items from
`libicudata`.

To list the default data items, run `zig build list`. From there, select the
items that are relevant to your project. If you want to see which items your
program uses _exactly_, follow
[this guide](https://unicode-org.github.io/icu/userguide/icu_data/tracing.html).

You may use glob syntax to specify batches of data items to remove:

```
zig build -Dicudata-removals="ibm* rfc3491.spp zone"
```

Or, if you have `icu-zig`, as a dependency:

```zig
const icu_dep = b.dependency(
    "icu",
    .{
        .target = target,
        .optimize = optimize,
        .@"icudata-removals" = "ibm* rfc3491.spp zone",
    },
);
```

## License

This package is licensed under the [MIT license](./LICENSE). The ICU project
v77.1 is licensed under the
[Unicode License v3](https://github.com/unicode-org/icu/blob/main/LICENSE). See
the full ICU license for all licenses of the dependencies of ICU.
