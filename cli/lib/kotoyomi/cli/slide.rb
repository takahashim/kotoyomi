# frozen_string_literal: true

class Kotoyomi::CLI
  # A single slide's parsed structure. Built mutably by Partitioner (arrays are
  # appended to as nodes are scanned), then consumed read-only by the renderers.
  #
  #   content_ids   : all content NodeRefs (flattened)
  #   regions       : content NodeRefs grouped per region ([[ref, ...], ...])
  #   layout        : nil | String  (named layout: cover / section / two-column / ...)
  #   speaker_notes : nil | String
  #   dynamic       : bool
  #   title         : nil | String
  #   player        : nil | { audio:, vtt: }
  Slide = Struct.new(
    :content_ids, :regions, :layout, :speaker_notes, :dynamic, :title, :player,
    keyword_init: true
  ) do
    # A blank slide ready to be filled in. Starts with one (empty) region; a
    # `> [column]` marker opens further regions.
    def self.blank
      new(
        content_ids: [],
        regions: [[]],
        layout: nil,
        speaker_notes: nil,
        dynamic: false,
        title: nil,
        player: nil
      )
    end

    # A slide carrying no content, notes, dynamic flag, or player is a
    # structural artifact (e.g. a trailing thematic break) and is dropped.
    def empty?
      content_ids.empty? && speaker_notes.nil? && !dynamic && player.nil?
    end

    # Content node ids grouped per non-empty region. Falls back to the flat
    # content_ids when every region is empty (e.g. a lone trailing `> [column]`).
    def content_regions
      non_empty = regions.reject(&:empty?)
      non_empty.empty? ? [content_ids] : non_empty
    end
  end
end
