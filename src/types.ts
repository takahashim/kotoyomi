export type PoemLine = {
  id: string;
  time: number;
  text: string;
};

export type PoemDocument = {
  title?: string;
  audioSrc: string;
  lines: PoemLine[];
};
