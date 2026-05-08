# Tests for the tree-VFS aspects of the bundled WASI preview1 impl
# (see js/wasi-preview1.js). Covers what mruby-io can drive from
# Ruby:
#   - File.read on a nested path that the JS host populated either
#     declaratively (fs.populate(new Directory({ ... }))) or via the
#     Map facade with auto-created intermediate directories.
#   - File.read / File.delete refusing to operate on a directory
#     (path_open returns E_ISDIR / path_unlink_file returns E_ISDIR).
#
# Tree mutations driven from Ruby (Dir.mkdir, Dir.entries, ...) need
# iij/mruby-dir or similar; without it the WASI primitives
# path_create_directory / fd_readdir aren't exposed to Ruby code.
# Their JS-level behaviour is asserted in runner.mjs instead.

Spec.describe "WASI tree VFS: nested File.read" do
  Spec.assert "File.read on a path populated via fs.populate(Directory{...})" do
    Spec.assert_equal "WEBVTT\n\nfixture\n", File.read("/data/poem.vtt")
  end

  Spec.assert "File.read on a path created via fs.set with intermediate dirs" do
    Spec.assert_equal "auto\ncreated\n", File.read("/auto/created/leaf.txt")
  end

  Spec.assert "missing nested path raises" do
    Spec.assert_raises(RuntimeError) { File.read("/data/no_such_file.vtt") }
  end
end

Spec.describe "WASI tree VFS: directories refuse file operations" do
  Spec.assert "File.read on a directory raises" do
    # /data is a Directory; path_open returns E_ISDIR, mruby surfaces it.
    Spec.assert_raises(RuntimeError) { File.read("/data") }
  end

  Spec.assert "File.read on the empty directory raises" do
    Spec.assert_raises(RuntimeError) { File.read("/empty_dir") }
  end

  Spec.assert "File.delete on a directory raises" do
    # path_unlink_file returns E_ISDIR; mruby raises.
    Spec.assert_raises(RuntimeError) { File.delete("/data") }
  end

  Spec.assert "File.write into a new file inside an existing dir" do
    File.open("/data/written_by_ruby.txt", "w") { |f| f.write("inside dir\n") }
    Spec.assert_equal "inside dir\n", File.read("/data/written_by_ruby.txt")
  end
end
