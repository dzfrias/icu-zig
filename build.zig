const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const icudata_remove_targets = b.option(
        []const []const u8,
        "icudata-removals",
        "Data items to remove from the ICU common data file",
    ) orelse &.{};

    const upstream = b.dependency("icu4c", .{});
    const source = upstream.path("source");

    const uconfig = std.Build.Step.Run.create(b, "Configure uconfig.h");
    uconfig.has_side_effects = true;
    uconfig.setCwd(source.path(b, ""));
    uconfig.expectExitCode(0);
    // The ICU build system prepends certain headers to uconfig.h to configure
    // the build. This script mimmics that.
    uconfig.addFileArg(b.path("uconfig.sh"));

    const icuuc = libicuuc(b, target, optimize);
    icuuc.step.dependOn(&uconfig.step);
    const icui18n = libicui18n(b, target, optimize);
    icui18n.step.dependOn(&uconfig.step);
    const icuio = libicuio(b, target, optimize);
    icuio.step.dependOn(&uconfig.step);

    const stubdata = libstubdata(b, target, optimize);
    const icutu = libicutu(b, target, optimize);
    // ICU uses a stub file in order to avoid a circular dependency between the
    // ICU tools (genccode, genrb, pkgdata, etc.) and libcuuc.
    //
    // Dependencies SHOULD go like this:
    //   icupkg --> -llibcuuc -licui18n -llibicudata -licutu
    // But since the tools are used to build libicudata, we do this for now:
    //   icupkg --> -llibcuuc -licui18n -llibstubdata -licutu
    const icupkg_bin = tool(
        b,
        "icupkg",
        &.{"icupkg/icupkg.cpp"},
        icuuc,
        stubdata,
        icui18n,
        icutu,
        target,
        optimize,
    );
    const is_be = target.result.cpu.arch.endian() == .big;
    const run_icu = std.Build.Step.Run.create(b, "Run icupkg");
    run_icu.has_side_effects = true;
    run_icu.setCwd(source);
    run_icu.expectExitCode(0);
    run_icu.addFileArg(b.path("icupkg.sh"));
    run_icu.addFileArg(icupkg_bin.getEmittedBin());
    run_icu.addArg(if (is_be) "1" else "0");
    run_icu.addArg("data/in/icudt77l.dat");
    const data_file_output = run_icu.addOutputFileArg("icudt77.dat");
    run_icu.addArgs(icudata_remove_targets);

    const genccode_bin = tool(
        b,
        "genccode",
        &.{"genccode/genccode.c"},
        icuuc,
        stubdata,
        icui18n,
        icutu,
        target,
        optimize,
    );
    // We use genccode to turn the common data file (`.dat`) (which is included
    // in the dependency archive) into a C source file that holds a static array
    // of all the bytes in the common data file.
    const gen_icudt_c = std.Build.Step.Run.create(b, "Run genccode");
    gen_icudt_c.has_side_effects = true;
    gen_icudt_c.setCwd(source.path(b, "data/in"));
    gen_icudt_c.expectExitCode(0);
    gen_icudt_c.addCheck(.{ .expect_stdout_match = "generating C code" });
    gen_icudt_c.addFileArg(b.path("genccode.sh"));
    gen_icudt_c.addFileArg(genccode_bin.getEmittedBin());
    gen_icudt_c.addFileArg(data_file_output);
    const icudt_c = gen_icudt_c.addOutputFileArg("icudt77_dat_final.c");

    // We then compile the outputted C source file into a static library. This
    // is libicudata.a
    const icudata = libicudata(b, icudt_c, icuuc, target, optimize);
    icudata.step.dependOn(&gen_icudt_c.step);

    icuuc.installHeadersDirectory(source.path(b, "common/unicode"), "unicode", .{});
    icui18n.installHeadersDirectory(source.path(b, "i18n/unicode"), "unicode", .{});
    icuio.installHeadersDirectory(source.path(b, "io/unicode"), "unicode", .{});
    b.installArtifact(icuuc);
    b.installArtifact(icui18n);
    b.installArtifact(icudata);
    b.installArtifact(icuio);
    b.installArtifact(icupkg_bin);
}

fn tool(
    b: *std.Build,
    name: []const u8,
    sources: []const []const u8,
    icuuc: *std.Build.Step.Compile,
    stubdata: *std.Build.Step.Compile,
    i18n: *std.Build.Step.Compile,
    toolutil: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const upstream = b.dependency("icu4c", .{});
    const tools = upstream.path("source/tools");

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .strip = true,
        }),
    });
    exe.linkLibCpp();
    exe.linkLibrary(i18n);
    exe.linkLibrary(icuuc);
    exe.linkLibrary(stubdata);
    exe.linkLibrary(toolutil);
    exe.addIncludePath(upstream.path("source/common"));
    exe.addIncludePath(upstream.path("source/i18n"));
    exe.addIncludePath(tools.path(b, name));
    exe.addIncludePath(tools.path(b, "toolutil"));
    exe.addCSourceFiles(.{
        .root = tools,
        .files = sources,
    });
    return exe;
}

fn libicutu(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const upstream = b.dependency("icu4c", .{});
    const tools = upstream.path("source/tools");

    const lib = b.addLibrary(.{
        .name = "icutu",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .strip = true,
        }),
        .linkage = .static,
    });
    lib.linkLibCpp();
    lib.addIncludePath(upstream.path("source/common"));
    lib.addIncludePath(upstream.path("source/i18n"));
    lib.addIncludePath(tools.path(b, "toolutil"));
    lib.addCSourceFiles(.{
        .root = tools,
        .files = &.{
            "toolutil/collationinfo.cpp",
            "toolutil/dbgutil.cpp",
            "toolutil/denseranges.cpp",
            "toolutil/filestrm.cpp",
            "toolutil/filetools.cpp",
            "toolutil/flagparser.cpp",
            "toolutil/package.cpp",
            "toolutil/pkg_genc.cpp",
            "toolutil/pkg_gencmn.cpp",
            "toolutil/pkg_icu.cpp",
            "toolutil/pkgitems.cpp",
            "toolutil/ppucd.cpp",
            "toolutil/swapimpl.cpp",
            "toolutil/toolutil.cpp",
            "toolutil/ucbuf.cpp",
            "toolutil/ucln_tu.cpp",
            "toolutil/ucm.cpp",
            "toolutil/ucmstate.cpp",
            "toolutil/udbgutil.cpp",
            "toolutil/unewdata.cpp",
            "toolutil/uoptions.cpp",
            "toolutil/uparse.cpp",
            "toolutil/writesrc.cpp",
            "toolutil/xmlparser.cpp",
        },
        .flags = &.{
            "-DU_TOOLUTIL_IMPLEMENTATION=1",
        },
    });
    return lib;
}

fn libicuio(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const upstream = b.dependency("icu4c", .{});
    const source = upstream.path("source");
    const lib = b.addLibrary(.{
        .name = "icuio",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .strip = true,
        }),
        .linkage = .static,
    });
    lib.linkLibCpp();
    lib.addIncludePath(source.path(b, "common"));
    lib.addIncludePath(source.path(b, "io"));
    lib.addIncludePath(source.path(b, "i18n"));
    lib.addCSourceFiles(.{
        .root = source,
        .files = &.{
            "io/locbund.cpp",
            "io/sprintf.cpp",
            "io/sscanf.cpp",
            "io/ucln_io.cpp",
            "io/ufile.cpp",
            "io/ufmt_cmn.cpp",
            "io/uprintf.cpp",
            "io/uprntf_p.cpp",
            "io/uscanf.cpp",
            "io/uscanf_p.cpp",
            "io/ustdio.cpp",
            "io/ustream.cpp",
        },
        .flags = &.{
            "-DU_IO_IMPLEMENTATION=1",
        },
    });
    return lib;
}

fn libicudata(
    b: *std.Build,
    source_file: std.Build.LazyPath,
    icuuc: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "icudata",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .strip = true,
        }),
        .linkage = .static,
    });
    lib.linkLibCpp();
    lib.linkLibrary(icuuc);
    lib.addCSourceFile(.{ .file = source_file });
    return lib;
}

fn libicui18n(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const upstream = b.dependency("icu4c", .{});
    const source = upstream.path("source");
    const lib = b.addLibrary(.{
        .name = "icui18n",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .strip = true,
        }),
        .linkage = .static,
    });
    lib.linkLibCpp();
    lib.addIncludePath(source.path(b, "common"));
    lib.addIncludePath(source.path(b, "i18n"));
    lib.addCSourceFiles(.{
        .root = source,
        .files = &.{
            "i18n/alphaindex.cpp",
            "i18n/anytrans.cpp",
            "i18n/astro.cpp",
            "i18n/basictz.cpp",
            "i18n/bocsu.cpp",
            "i18n/brktrans.cpp",
            "i18n/buddhcal.cpp",
            "i18n/calendar.cpp",
            "i18n/casetrn.cpp",
            "i18n/cecal.cpp",
            "i18n/chnsecal.cpp",
            "i18n/choicfmt.cpp",
            "i18n/coleitr.cpp",
            "i18n/coll.cpp",
            "i18n/collation.cpp",
            "i18n/collationbuilder.cpp",
            "i18n/collationcompare.cpp",
            "i18n/collationdata.cpp",
            "i18n/collationdatabuilder.cpp",
            "i18n/collationdatareader.cpp",
            "i18n/collationdatawriter.cpp",
            "i18n/collationfastlatin.cpp",
            "i18n/collationfastlatinbuilder.cpp",
            "i18n/collationfcd.cpp",
            "i18n/collationiterator.cpp",
            "i18n/collationkeys.cpp",
            "i18n/collationroot.cpp",
            "i18n/collationrootelements.cpp",
            "i18n/collationruleparser.cpp",
            "i18n/collationsets.cpp",
            "i18n/collationsettings.cpp",
            "i18n/collationtailoring.cpp",
            "i18n/collationweights.cpp",
            "i18n/compactdecimalformat.cpp",
            "i18n/coptccal.cpp",
            "i18n/cpdtrans.cpp",
            "i18n/csdetect.cpp",
            "i18n/csmatch.cpp",
            "i18n/csr2022.cpp",
            "i18n/csrecog.cpp",
            "i18n/csrmbcs.cpp",
            "i18n/csrsbcs.cpp",
            "i18n/csrucode.cpp",
            "i18n/csrutf8.cpp",
            "i18n/curramt.cpp",
            "i18n/currfmt.cpp",
            "i18n/currpinf.cpp",
            "i18n/currunit.cpp",
            "i18n/dangical.cpp",
            "i18n/datefmt.cpp",
            "i18n/dayperiodrules.cpp",
            "i18n/dcfmtsym.cpp",
            "i18n/decContext.cpp",
            "i18n/decNumber.cpp",
            "i18n/decimfmt.cpp",
            "i18n/displayoptions.cpp",
            "i18n/double-conversion-bignum-dtoa.cpp",
            "i18n/double-conversion-bignum.cpp",
            "i18n/double-conversion-cached-powers.cpp",
            "i18n/double-conversion-double-to-string.cpp",
            "i18n/double-conversion-fast-dtoa.cpp",
            "i18n/double-conversion-string-to-double.cpp",
            "i18n/double-conversion-strtod.cpp",
            "i18n/dtfmtsym.cpp",
            "i18n/dtitvfmt.cpp",
            "i18n/dtitvinf.cpp",
            "i18n/dtptngen.cpp",
            "i18n/dtrule.cpp",
            "i18n/erarules.cpp",
            "i18n/esctrn.cpp",
            "i18n/ethpccal.cpp",
            "i18n/fmtable.cpp",
            "i18n/fmtable_cnv.cpp",
            "i18n/format.cpp",
            "i18n/formatted_string_builder.cpp",
            "i18n/formattedval_iterimpl.cpp",
            "i18n/formattedval_sbimpl.cpp",
            "i18n/formattedvalue.cpp",
            "i18n/fphdlimp.cpp",
            "i18n/fpositer.cpp",
            "i18n/funcrepl.cpp",
            "i18n/gender.cpp",
            "i18n/gregocal.cpp",
            "i18n/gregoimp.cpp",
            "i18n/hebrwcal.cpp",
            "i18n/indiancal.cpp",
            "i18n/inputext.cpp",
            "i18n/islamcal.cpp",
            "i18n/iso8601cal.cpp",
            "i18n/japancal.cpp",
            "i18n/listformatter.cpp",
            "i18n/measfmt.cpp",
            "i18n/measunit.cpp",
            "i18n/measunit_extra.cpp",
            "i18n/measure.cpp",
            "i18n/msgfmt.cpp",
            "i18n/messageformat2.cpp",
            "i18n/messageformat2_arguments.cpp",
            "i18n/messageformat2_checker.cpp",
            "i18n/messageformat2_data_model.cpp",
            "i18n/messageformat2_errors.cpp",
            "i18n/messageformat2_evaluation.cpp",
            "i18n/messageformat2_formatter.cpp",
            "i18n/messageformat2_formattable.cpp",
            "i18n/messageformat2_function_registry.cpp",
            "i18n/messageformat2_parser.cpp",
            "i18n/messageformat2_serializer.cpp",
            "i18n/name2uni.cpp",
            "i18n/nfrs.cpp",
            "i18n/nfrule.cpp",
            "i18n/nfsubs.cpp",
            "i18n/nortrans.cpp",
            "i18n/nultrans.cpp",
            "i18n/number_affixutils.cpp",
            "i18n/number_asformat.cpp",
            "i18n/number_capi.cpp",
            "i18n/number_compact.cpp",
            "i18n/number_currencysymbols.cpp",
            "i18n/number_decimalquantity.cpp",
            "i18n/number_decimfmtprops.cpp",
            "i18n/number_fluent.cpp",
            "i18n/number_formatimpl.cpp",
            "i18n/number_grouping.cpp",
            "i18n/number_integerwidth.cpp",
            "i18n/number_longnames.cpp",
            "i18n/number_mapper.cpp",
            "i18n/number_modifiers.cpp",
            "i18n/number_multiplier.cpp",
            "i18n/number_notation.cpp",
            "i18n/number_output.cpp",
            "i18n/number_padding.cpp",
            "i18n/number_patternmodifier.cpp",
            "i18n/number_patternstring.cpp",
            "i18n/number_rounding.cpp",
            "i18n/number_scientific.cpp",
            "i18n/number_simple.cpp",
            "i18n/number_skeletons.cpp",
            "i18n/number_symbolswrapper.cpp",
            "i18n/number_usageprefs.cpp",
            "i18n/number_utils.cpp",
            "i18n/numfmt.cpp",
            "i18n/numparse_affixes.cpp",
            "i18n/numparse_compositions.cpp",
            "i18n/numparse_currency.cpp",
            "i18n/numparse_decimal.cpp",
            "i18n/numparse_impl.cpp",
            "i18n/numparse_parsednumber.cpp",
            "i18n/numparse_scientific.cpp",
            "i18n/numparse_symbols.cpp",
            "i18n/numparse_validators.cpp",
            "i18n/numrange_capi.cpp",
            "i18n/numrange_fluent.cpp",
            "i18n/numrange_impl.cpp",
            "i18n/numsys.cpp",
            "i18n/olsontz.cpp",
            "i18n/persncal.cpp",
            "i18n/pluralranges.cpp",
            "i18n/plurfmt.cpp",
            "i18n/plurrule.cpp",
            "i18n/quant.cpp",
            "i18n/quantityformatter.cpp",
            "i18n/rbnf.cpp",
            "i18n/rbt.cpp",
            "i18n/rbt_data.cpp",
            "i18n/rbt_pars.cpp",
            "i18n/rbt_rule.cpp",
            "i18n/rbt_set.cpp",
            "i18n/rbtz.cpp",
            "i18n/regexcmp.cpp",
            "i18n/regeximp.cpp",
            "i18n/regexst.cpp",
            "i18n/regextxt.cpp",
            "i18n/region.cpp",
            "i18n/reldatefmt.cpp",
            "i18n/reldtfmt.cpp",
            "i18n/rematch.cpp",
            "i18n/remtrans.cpp",
            "i18n/repattrn.cpp",
            "i18n/rulebasedcollator.cpp",
            "i18n/scientificnumberformatter.cpp",
            "i18n/scriptset.cpp",
            "i18n/search.cpp",
            "i18n/selfmt.cpp",
            "i18n/sharedbreakiterator.cpp",
            "i18n/simpletz.cpp",
            "i18n/smpdtfmt.cpp",
            "i18n/smpdtfst.cpp",
            "i18n/sortkey.cpp",
            "i18n/standardplural.cpp",
            "i18n/string_segment.cpp",
            "i18n/strmatch.cpp",
            "i18n/strrepl.cpp",
            "i18n/stsearch.cpp",
            "i18n/taiwncal.cpp",
            "i18n/timezone.cpp",
            "i18n/titletrn.cpp",
            "i18n/tmunit.cpp",
            "i18n/tmutamt.cpp",
            "i18n/tmutfmt.cpp",
            "i18n/tolowtrn.cpp",
            "i18n/toupptrn.cpp",
            "i18n/translit.cpp",
            "i18n/transreg.cpp",
            "i18n/tridpars.cpp",
            "i18n/tzfmt.cpp",
            "i18n/tzgnames.cpp",
            "i18n/tznames.cpp",
            "i18n/tznames_impl.cpp",
            "i18n/tzrule.cpp",
            "i18n/tztrans.cpp",
            "i18n/ucal.cpp",
            "i18n/ucln_in.cpp",
            "i18n/ucol.cpp",
            "i18n/ucol_res.cpp",
            "i18n/ucol_sit.cpp",
            "i18n/ucoleitr.cpp",
            "i18n/ucsdet.cpp",
            "i18n/udat.cpp",
            "i18n/udateintervalformat.cpp",
            "i18n/udatpg.cpp",
            "i18n/ufieldpositer.cpp",
            "i18n/uitercollationiterator.cpp",
            "i18n/ulistformatter.cpp",
            "i18n/ulocdata.cpp",
            "i18n/umsg.cpp",
            "i18n/unesctrn.cpp",
            "i18n/uni2name.cpp",
            "i18n/units_data.cpp",
            "i18n/units_complexconverter.cpp",
            "i18n/units_converter.cpp",
            "i18n/units_router.cpp",
            "i18n/unum.cpp",
            "i18n/unumsys.cpp",
            "i18n/upluralrules.cpp",
            "i18n/uregex.cpp",
            "i18n/uregexc.cpp",
            "i18n/uregion.cpp",
            "i18n/usearch.cpp",
            "i18n/uspoof.cpp",
            "i18n/uspoof_build.cpp",
            "i18n/uspoof_conf.cpp",
            "i18n/uspoof_impl.cpp",
            "i18n/utf16collationiterator.cpp",
            "i18n/utf8collationiterator.cpp",
            "i18n/utmscale.cpp",
            "i18n/utrans.cpp",
            "i18n/vtzone.cpp",
            "i18n/vzone.cpp",
            "i18n/windtfmt.cpp",
            "i18n/winnmfmt.cpp",
            "i18n/wintzimpl.cpp",
            "i18n/zonemeta.cpp",
            "i18n/zrule.cpp",
            "i18n/ztrans.cpp",
        },
        .flags = &.{
            "-DU_I18N_IMPLEMENTATION=1",
            "-DU_DISABLE_RENAMING=1",
        },
    });

    return lib;
}

fn libicuuc(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const upstream = b.dependency("icu4c", .{});
    const source = upstream.path("source");
    const lib = b.addLibrary(.{
        .name = "icuuc",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .strip = true,
        }),
        .linkage = .static,
    });
    lib.linkLibCpp();
    lib.addIncludePath(source.path(b, "common"));
    lib.addCSourceFiles(.{
        .root = source,
        .files = &.{
            "common/appendable.cpp",
            "common/bmpset.cpp",
            "common/brkeng.cpp",
            "common/brkiter.cpp",
            "common/bytesinkutil.cpp",
            "common/bytestream.cpp",
            "common/bytestrie.cpp",
            "common/bytestriebuilder.cpp",
            "common/bytestrieiterator.cpp",
            "common/caniter.cpp",
            "common/characterproperties.cpp",
            "common/chariter.cpp",
            "common/charstr.cpp",
            "common/cmemory.cpp",
            "common/cstr.cpp",
            "common/cstring.cpp",
            "common/cwchar.cpp",
            "common/dictbe.cpp",
            "common/dictionarydata.cpp",
            "common/dtintrv.cpp",
            "common/edits.cpp",
            "common/emojiprops.cpp",
            "common/errorcode.cpp",
            "common/filteredbrk.cpp",
            "common/filterednormalizer2.cpp",
            "common/icudataver.cpp",
            "common/icuplug.cpp",
            "common/loadednormalizer2impl.cpp",
            "common/localebuilder.cpp",
            "common/localematcher.cpp",
            "common/localeprioritylist.cpp",
            "common/locavailable.cpp",
            "common/locbased.cpp",
            "common/locdispnames.cpp",
            "common/locdistance.cpp",
            "common/locdspnm.cpp",
            "common/locid.cpp",
            "common/loclikely.cpp",
            "common/loclikelysubtags.cpp",
            "common/locmap.cpp",
            "common/locresdata.cpp",
            "common/locutil.cpp",
            "common/lsr.cpp",
            "common/lstmbe.cpp",
            "common/messagepattern.cpp",
            "common/mlbe.cpp",
            "common/normalizer2.cpp",
            "common/normalizer2impl.cpp",
            "common/normlzr.cpp",
            "common/parsepos.cpp",
            "common/patternprops.cpp",
            "common/pluralmap.cpp",
            "common/propname.cpp",
            "common/propsvec.cpp",
            "common/punycode.cpp",
            "common/putil.cpp",
            "common/rbbi.cpp",
            "common/rbbi_cache.cpp",
            "common/rbbidata.cpp",
            "common/rbbinode.cpp",
            "common/rbbirb.cpp",
            "common/rbbiscan.cpp",
            "common/rbbisetb.cpp",
            "common/rbbistbl.cpp",
            "common/rbbitblb.cpp",
            "common/resbund.cpp",
            "common/resbund_cnv.cpp",
            "common/resource.cpp",
            "common/restrace.cpp",
            "common/ruleiter.cpp",
            "common/schriter.cpp",
            "common/serv.cpp",
            "common/servlk.cpp",
            "common/servlkf.cpp",
            "common/servls.cpp",
            "common/servnotf.cpp",
            "common/servrbf.cpp",
            "common/servslkf.cpp",
            "common/sharedobject.cpp",
            "common/simpleformatter.cpp",
            "common/static_unicode_sets.cpp",
            "common/stringpiece.cpp",
            "common/stringtriebuilder.cpp",
            "common/uarrsort.cpp",
            "common/ubidi.cpp",
            "common/ubidi_props.cpp",
            "common/ubidiln.cpp",
            "common/ubiditransform.cpp",
            "common/ubidiwrt.cpp",
            "common/ubrk.cpp",
            "common/ucase.cpp",
            "common/ucasemap.cpp",
            "common/ucasemap_titlecase_brkiter.cpp",
            "common/ucat.cpp",
            "common/uchar.cpp",
            "common/ucharstrie.cpp",
            "common/ucharstriebuilder.cpp",
            "common/ucharstrieiterator.cpp",
            "common/uchriter.cpp",
            "common/ucln_cmn.cpp",
            "common/ucmndata.cpp",
            "common/ucnv.cpp",
            "common/ucnv2022.cpp",
            "common/ucnv_bld.cpp",
            "common/ucnv_cb.cpp",
            "common/ucnv_cnv.cpp",
            "common/ucnv_ct.cpp",
            "common/ucnv_err.cpp",
            "common/ucnv_ext.cpp",
            "common/ucnv_io.cpp",
            "common/ucnv_lmb.cpp",
            "common/ucnv_set.cpp",
            "common/ucnv_u16.cpp",
            "common/ucnv_u32.cpp",
            "common/ucnv_u7.cpp",
            "common/ucnv_u8.cpp",
            "common/ucnvbocu.cpp",
            "common/ucnvdisp.cpp",
            "common/ucnvhz.cpp",
            "common/ucnvisci.cpp",
            "common/ucnvlat1.cpp",
            "common/ucnvmbcs.cpp",
            "common/ucnvscsu.cpp",
            "common/ucnvsel.cpp",
            "common/ucol_swp.cpp",
            "common/ucptrie.cpp",
            "common/ucurr.cpp",
            "common/udata.cpp",
            "common/udatamem.cpp",
            "common/udataswp.cpp",
            "common/uenum.cpp",
            "common/uhash.cpp",
            "common/uhash_us.cpp",
            "common/uidna.cpp",
            "common/uinit.cpp",
            "common/uinvchar.cpp",
            "common/uiter.cpp",
            "common/ulist.cpp",
            "common/uloc.cpp",
            "common/uloc_keytype.cpp",
            "common/uloc_tag.cpp",
            "common/ulocale.cpp",
            "common/ulocbuilder.cpp",
            "common/umapfile.cpp",
            "common/umath.cpp",
            "common/umutablecptrie.cpp",
            "common/umutex.cpp",
            "common/unames.cpp",
            "common/unifiedcache.cpp",
            "common/unifilt.cpp",
            "common/unifunct.cpp",
            "common/uniset.cpp",
            "common/uniset_closure.cpp",
            "common/uniset_props.cpp",
            "common/unisetspan.cpp",
            "common/unistr.cpp",
            "common/unistr_case.cpp",
            "common/unistr_case_locale.cpp",
            "common/unistr_cnv.cpp",
            "common/unistr_props.cpp",
            "common/unistr_titlecase_brkiter.cpp",
            "common/unorm.cpp",
            "common/unormcmp.cpp",
            "common/uobject.cpp",
            "common/uprops.cpp",
            "common/ures_cnv.cpp",
            "common/uresbund.cpp",
            "common/uresdata.cpp",
            "common/usc_impl.cpp",
            "common/uscript.cpp",
            "common/uscript_props.cpp",
            "common/uset.cpp",
            "common/uset_props.cpp",
            "common/usetiter.cpp",
            "common/ushape.cpp",
            "common/usprep.cpp",
            "common/ustack.cpp",
            "common/ustr_cnv.cpp",
            "common/ustr_titlecase_brkiter.cpp",
            "common/ustr_wcs.cpp",
            "common/ustrcase.cpp",
            "common/ustrcase_locale.cpp",
            "common/ustrenum.cpp",
            "common/ustrfmt.cpp",
            "common/ustring.cpp",
            "common/ustrtrns.cpp",
            "common/utext.cpp",
            "common/utf_impl.cpp",
            "common/util.cpp",
            "common/util_props.cpp",
            "common/utrace.cpp",
            "common/utrie.cpp",
            "common/utrie2.cpp",
            "common/utrie2_builder.cpp",
            "common/utrie_swap.cpp",
            "common/uts46.cpp",
            "common/utypes.cpp",
            "common/uvector.cpp",
            "common/uvectr32.cpp",
            "common/uvectr64.cpp",
            "common/wintz.cpp",
        },
        .flags = &.{
            "-DU_COMMON_IMPLEMENTATION=1",
            "-DU_DISABLE_RENAMING=1",
        },
    });
    return lib;
}

fn libstubdata(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const upstream = b.dependency("icu4c", .{});
    const source = upstream.path("source");
    const lib = b.addLibrary(.{
        .name = "libstubdata",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .strip = true,
        }),
        .linkage = .static,
    });
    lib.linkLibCpp();
    lib.addIncludePath(source.path(b, "common"));
    lib.addIncludePath(source.path(b, "stubdata"));
    lib.addCSourceFiles(.{
        .root = source,
        .files = &.{
            "stubdata/stubdata.cpp",
        },
    });
    return lib;
}
