# Tests for mruby-wasi-dir against the bundled WASI preview1
# implementation. Exercises path_open(O_DIRECTORY) + fd_readdir +
# path_create_directory + path_remove_directory + path_filestat_get
# end-to-end via wasi-libc's <dirent.h> + <sys/stat.h>.
#
# Tree fixtures in runner.mjs:
#   /spec_fixture.txt
#   /spec_binary.dat
#   /data/poem.vtt
#   /empty_dir/
#   /auto/created/leaf.txt

Spec.describe "Dir.entries" do
  Spec.assert "lists root entries (includes the populated fixtures)" do
    names = Dir.entries("/")
    Spec.assert_true names.include?("data")
    Spec.assert_true names.include?("spec_fixture.txt")
    Spec.assert_true names.include?("empty_dir")
  end

  Spec.assert "includes . and .. (CRuby parity)" do
    names = Dir.entries("/data")
    Spec.assert_true names.include?(".")
    Spec.assert_true names.include?("..")
  end

  Spec.assert "lists nested directory contents" do
    names = Dir.entries("/data") - [".", ".."]
    Spec.assert_true names.include?("poem.vtt")
  end

  Spec.assert "empty directory yields only . and .." do
    names = Dir.entries("/empty_dir")
    Spec.assert_equal [".", ".."].sort, names.sort
  end

  Spec.assert "missing path raises" do
    Spec.assert_raises(RuntimeError) { Dir.entries("/no_such_dir") }
  end

  Spec.assert "raises on a regular-file path" do
    # path_open(O_DIRECTORY) on a file → E_NOTDIR
    Spec.assert_raises(RuntimeError) { Dir.entries("/spec_fixture.txt") }
  end
end

Spec.describe "Dir.mkdir / Dir.rmdir" do
  Spec.assert "mkdir creates, rmdir removes" do
    Dir.mkdir("/test_md_dir")
    Spec.assert_true Dir.exist?("/test_md_dir")
    Dir.rmdir("/test_md_dir")
    Spec.assert_false Dir.exist?("/test_md_dir")
  end

  Spec.assert "mkdir + populate + readdir round-trip" do
    Dir.mkdir("/test_populated")
    File.open("/test_populated/a.txt", "w") { |f| f.write("a\n") }
    File.open("/test_populated/b.txt", "w") { |f| f.write("b\n") }
    names = Dir.entries("/test_populated") - [".", ".."]
    Spec.assert_equal ["a.txt", "b.txt"], names.sort
    File.delete("/test_populated/a.txt")
    File.delete("/test_populated/b.txt")
    Dir.rmdir("/test_populated")
  end

  Spec.assert "mkdir on existing path raises" do
    Spec.assert_raises(RuntimeError) { Dir.mkdir("/data") }
  end

  Spec.assert "rmdir on non-existent raises" do
    Spec.assert_raises(RuntimeError) { Dir.rmdir("/no_such_dir") }
  end

  Spec.assert "rmdir on non-empty directory raises (E_NOTEMPTY)" do
    Spec.assert_raises(RuntimeError) { Dir.rmdir("/data") }
  end

  Spec.assert "rmdir on a file path raises" do
    # path_remove_directory on a file → E_NOTDIR
    Spec.assert_raises(RuntimeError) { Dir.rmdir("/spec_fixture.txt") }
  end
end

Spec.describe "Dir.exist?" do
  Spec.assert "true for an existing directory" do
    Spec.assert_true Dir.exist?("/data")
  end

  Spec.assert "false for a regular file" do
    Spec.assert_false Dir.exist?("/spec_fixture.txt")
  end

  Spec.assert "false for a missing path" do
    Spec.assert_false Dir.exist?("/no_such")
  end

  Spec.assert "exists? alias works" do
    Spec.assert_true Dir.exists?("/data")
  end
end

Spec.describe "Dir.foreach" do
  Spec.assert "yields each entry with a block" do
    seen = []
    Dir.foreach("/empty_dir") { |name| seen << name }
    Spec.assert_equal [".", ".."].sort, seen.sort
  end

  Spec.assert "without a block returns an enumerator" do
    e = Dir.foreach("/data")
    names = e.to_a
    Spec.assert_true names.include?("poem.vtt")
  end
end
