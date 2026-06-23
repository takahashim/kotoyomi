module Kotoyomi
  # VTT 文字列を Blob URL 化して <track>/<audio> に流す薄い JS 副作用層。
  # これがあるおかげで Player/Renderer は DOM/JS に触れない純ドメインのまま
  # 保てる。slides.json には音声パスと VTT 本文(文字列)だけが載るので、
  # 別 .vtt ファイルを用意せずブラウザの TextTrack パースをそのまま使える。
  module VttTrack
    # track.src に VTT 文字列の Blob URL を、audio.src に音声パスを設定し、
    # 後で revoke するための Blob URL を返す。
    def self.attach(track, audio, vtt_string, audio_path)
      url = Lilac.create_object_url(vtt_string, type: "text/vtt")
      track[:src] = url
      audio[:src] = audio_path.to_s
      url
    end

    def self.revoke(url)
      Lilac.revoke_object_url(url)
    end
  end
end
