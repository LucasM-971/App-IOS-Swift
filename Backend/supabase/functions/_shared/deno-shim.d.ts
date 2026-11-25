declare const Deno: {
  env: {
    get(key: string): string | undefined;
  };
  serve: (handler: (req: Request) => Response | Promise<Response>) => unknown;
  test: (
    name: string,
    fn: () => void | Promise<void>,
  ) => unknown;
};
