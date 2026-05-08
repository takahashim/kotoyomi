# Pure-Ruby helpers on top of the C primitives in src/dir.c.

class Dir
  def self.foreach(path)
    return entries(path).each unless block_given?
    entries(path).each { |name| yield name }
  end

  class << self
    alias_method :delete, :rmdir
    alias_method :unlink, :rmdir
    alias_method :exists?, :exist?
  end
end
