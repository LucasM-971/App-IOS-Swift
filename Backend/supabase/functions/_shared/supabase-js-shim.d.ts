// Shim de types pour l'éditeur : les `any` sont volontaires.
// deno-lint-ignore-file no-explicit-any
declare module "npm:@supabase/supabase-js@2.49.1" {
  export type SupabaseClient = {
    auth: {
      getUser: (
        token?: string,
      ) => Promise<
        { data: { user: any | null }; error: { message?: string } | null }
      >;
      signUp: (payload: any) => Promise<any>;
      signInWithPassword: (payload: any) => Promise<any>;
      resend: (payload: any) => Promise<any>;
      verifyOtp: (payload: any) => Promise<any>;
      resetPasswordForEmail: (email: string, options?: any) => Promise<any>;
      admin: {
        updateUserById: (id: string, payload: any) => Promise<any>;
        deleteUser: (id: string) => Promise<any>;
        getUserById: (id: string) => Promise<any>;
        generateLink: (payload: any) => Promise<any>;
      };
    };
    from: (table: string) => any;
  };

  export function createClient(
    url: string,
    key: string,
    options?: any,
  ): SupabaseClient;
}

// Loading history
