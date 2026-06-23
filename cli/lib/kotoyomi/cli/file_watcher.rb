# frozen_string_literal: true

class Kotoyomi::CLI
  # 単一ファイルの mtime をポーリングし、変化のたびにブロックを呼ぶ。gem を増やさ
  # ないための素朴な監視。初回(変化前)は呼ばない ─ 初回ビルドは呼び出し側で
  # 済ませる前提なので、監視は「変化への反応」だけに責務を絞る。
  # ブロック内の例外は握らない(再ビルド失敗を続行するかは呼び出し側の判断)。
  class FileWatcher
    def initialize(path, interval:)
      @path = path
      @interval = interval
    end

    def each_change
      last = mtime
      loop do
        sleep(@interval)
        current = mtime
        # 消えている間(エディタの削除→再作成保存や一時 rename)は nil。落とさず
        # 待ち続け、再作成されれば last と異なるので次の変化として拾う。
        next if current.nil? || current == last

        last = current
        yield
      end
    end

    private

    def mtime
      File.mtime(@path)
    rescue Errno::ENOENT
      nil
    end
  end
end
