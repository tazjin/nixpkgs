# Go through all imported NixOS modules and build a module
# documentation book.
#
# This should work out-of-the-box with all NixOS modules and generate
# reasonable enough documentation for their configuration options.

{ pkgs ? import ./. {}
, moduleList ? ./nixos/modules/module-list.nix }:

let
  lib = pkgs.lib;

  # Used to call modules without actually specifying anything.
  # Laziness allows us to inspect only the interesting bits of the
  # configuration without this causing issues.
  dummyArgs = {
    inherit pkgs lib;
    config = {};
    utils = {};
    baseModules = {};
    extraModules = {};
    modules = {};
    options = {};
    services = {};
  };

  # Determine whether an attribute set is an option.
  isOption = s: (builtins.hasAttr "_type" s) && (s._type == "option");

  # Recursively flatten an attribute set, stopping at all nested
  # attribute sets that meet 'cond' or at anything that isn't an
  # attribute set.
  flattenAttrs = cond: attrs: lib.flatten (flattenAttrs' cond attrs);
  flattenAttrs' = with builtins; cond: attrs: map
    (val: if isAttrs val && !(cond val) then flattenAttrs' cond val else val)
    (attrValues attrs);

  # Extract relevant information out of a single option.
  docOpt = path: opt: {
    inherit path;
    name = lib.concatStringsSep "." path;
    type = if opt ? "type" then opt.type.description else "<none>";
    desc = if opt ? "description" then (builtins.replaceStrings ["\n"] [" "] opt.description) else "<none>";
    visible = if opt ? "visible" then opt.visible else true;
  } // (if opt ? "example" then {
    example = lib.generators.toPretty {} opt.example;
  } else {});

  # Traverse a module to extract its documentation and options.
  docMod = with lib; module:
  let mod = import module dummyArgs;
  in {
    name = removeSuffix ".nix" (builtins.baseNameOf module);
    # TODO(tazjin): If the module has its own folder (i.e. module
    # basename is `default.nix`) and a `README.md` exists, load that
    # instead of a module doc comment.
    docFile = if (lib.hasSuffix ".nix" (builtins.baseNameOf module))
      then "${module}"
      else "${module}/default.nix";
  } // (if mod ? "options" then {
    options = flattenAttrs (s: (s ? "name") && (builtins.isString s.name))
                           (mapAttrsRecursiveCond (s: !isOption s) docOpt mod.options);
  } else {});

  # Convert a module into its Markdown representation.
  mod2md = with pkgs; mod: runCommand "${mod.name}-docs.md" {
    PATH = "${gnused}/bin:${coreutils}/bin";
    OPTS_TABLE = writeText "${mod.name}-opts.md" (if !(mod ? "options") then "" else (''
      |option|type|description|
      |------|----|-----------|
    ''
    + lib.concatStrings (map (opt: "|${opt.name}|${opt.type}|${opt.desc}|\n") mod.options)));
  } ''
    echo '# ${mod.name}' > $out

    # Extract the documentation header from a module (assumed to be
    # the first few commented-out lines)
    cat ${mod.docFile} | sed -n '/^#/,/^$/P' | sed 's/#\s//g' >> $out

    # Finally write the options table if it was generated:
    cat $OPTS_TABLE >> $out
  '';

  # Convert a relative path to a string (required because toString
  # creates absolute paths).
  relPath = path: lib.removePrefix "${toString ./.}/" "${toString path}";

  # Convert a string representing a relative path to an absolute path.
  absPath = path: builtins.toPath "${toString ./.}/${path}";

  # Write a SUMMARY.md entry for each module in the module list,
  # including "parent" entries for each folder along the way.
  summarise = modules: with lib; with builtins;
  let
    moduleTree = foldl' recursiveUpdate {} (map summarise' modules);
    indent = n: fixedWidthString (n * 2) " " "";
    indentWrite = n: t: foldl' (s: k: let v = t."${k}"; in
      if v ? "name"
      # Write a module entry. For unknown reasons, mdBook refuses to
      # load chapters from absolute paths. To work around this links
      # are relative using the basename of the store path which is
      # later linked in the correct place.
      then s + (indent n) + "- [${v.name}](${baseNameOf (toString (mod2md v))})\n"
      # Write a category entry
      else s + (indent n) + "- [${k}](./${k}.md)]\n" + (indentWrite (n + 1) v)
    ) "" (attrNames t);
  in {
    modules = flattenAttrs (s: s ? "name") moduleTree;
    summary = pkgs.writeText "module-summary.md" ''
      # NixOS modules
      ${indentWrite 0 moduleTree}
    '';
  };

  summarise' = module: with lib; with builtins;
  # Create a normalised path for the documentation index which
  # ignores whether the module is a single-file, in its own folder
  # or whatever else.
  let path = map (removeSuffix ".nix")
                 (filter
                   (s: s != "default.nix")
                   # The two dropped elements are [ "nixos" "modules" ]
                   (drop 2 (splitString "/" (relPath module))));
  in setAttrByPath path (docMod module);

  bookConfig = pkgs.writeText "book.toml" ''
    [book]
    authors = []
    language = "en"
    multilingual = false
    src = "src"
  '';

  data = summarise (import moduleList);
in with lib; with pkgs; runCommand "nixos-modules-book" {} ''
  mkdir -p $out src

  # Create the required file structure
  cp ${bookConfig} book.toml
  cp ${data.summary} src/SUMMARY.md

  ${concatStrings (map (mod:
  let docs = mod2md mod;
  in "ln -s ${docs} src/${builtins.baseNameOf docs}\n"
  ) data.modules) }

  ${mdbook}/bin/mdbook build -d $out
''
