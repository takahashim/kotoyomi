import { parsePoem, PoemParseError } from "../src/parser.ts";

async function main(): Promise<number> {
  const path = Deno.args[0];
  if (!path) {
    console.error("usage: deno run --allow-read tools/validate_poem.ts <path>");
    return 2;
  }

  let source: string;
  try {
    source = await Deno.readTextFile(path);
  } catch (err) {
    console.error(`ファイルを読み込めません: ${path}`);
    console.error(err instanceof Error ? err.message : String(err));
    return 1;
  }

  try {
    const lines = parsePoem(source);
    console.log(JSON.stringify(lines, null, 2));
    return 0;
  } catch (err) {
    if (err instanceof PoemParseError) {
      console.error(err.message);
    } else {
      console.error(err instanceof Error ? err.message : String(err));
    }
    return 1;
  }
}

Deno.exit(await main());
