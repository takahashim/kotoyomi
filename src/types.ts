export type PoemStanza = {
  id: string;
  time: number;
  lines: string[];
};

export type PoemDocument = {
  title?: string;
  audioSrc: string;
  stanzas: PoemStanza[];
};
