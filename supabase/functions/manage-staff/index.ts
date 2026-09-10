import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// Creating auth users, resetting their passwords and deleting them all need the
// service role key, which must never reach the browser. This function is the
// gateway for those operations. Every action but `change_own_password` is
// restricted to administrators.

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const PASSWORD_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function generatePassword(length = 12): string {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => PASSWORD_ALPHABET[b % PASSWORD_ALPHABET.length])
    .join("");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Only POST is supported." }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // Establish who is calling before trusting anything in the body.
  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) {
    return json({ error: "Missing authorization header." }, 401);
  }

  const { data: caller, error: callerError } = await admin.auth.getUser(token);
  if (callerError || !caller?.user) {
    return json({ error: "Your session is no longer valid." }, 401);
  }

  const { data: callerProfile } = await admin
    .from("profiles")
    .select("role, is_active")
    .eq("id", caller.user.id)
    .maybeSingle();

  if (!callerProfile || !callerProfile.is_active) {
    return json({ error: "This account is not active." }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Request body must be JSON." }, 400);
  }

  const action = String(body.action ?? "");

  // Choosing your own password is the one thing a non-admin does here. The
  // password itself is updated with the caller's JWT so GoTrue keeps this
  // session and only revokes others. Clearing must_change_password still needs
  // the service role, and only runs after the password write succeeded.
  if (action === "change_own_password") {
    const password = String(body.password ?? "");
    if (password.length < 8) {
      return json({ error: "Passwords must be at least 8 characters." }, 400);
    }

    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const asCaller = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { error } = await asCaller.auth.updateUser({ password });
    if (error) {
      const code = (error as { code?: string }).code ?? "";
      if (code === "same_password") {
        return json(
          {
            error:
              "That is already your current password. Choose a different one.",
          },
          400,
        );
      }
      if (code === "weak_password") {
        return json(
          {
            error:
              "That password is too easy to guess. Use at least 8 characters with a mix of letters and numbers.",
          },
          400,
        );
      }
      return json(
        { error: "That password could not be saved. Please try another one." },
        400,
      );
    }

    await admin
      .from("profiles")
      .update({ must_change_password: false })
      .eq("id", caller.user.id);

    return json({ user_id: caller.user.id, changed: true });
  }

  if (callerProfile.role !== "admin") {
    return json({ error: "Only administrators can manage staff accounts." }, 403);
  }

  if (action === "create") {
    const email = String(body.email ?? "").trim().toLowerCase();
    const fullName = String(body.full_name ?? "").trim();
    const staffId = String(body.staff_id ?? "").trim();
    const role = body.role === "admin" ? "admin" : "staff";

    if (!email || !email.includes("@")) {
      return json({ error: "A valid email address is required." }, 400);
    }
    if (!fullName) {
      return json({ error: "The staff member's full name is required." }, 400);
    }

    const password = String(body.password ?? "").trim() || generatePassword();
    if (password.length < 8) {
      return json({ error: "Passwords must be at least 8 characters." }, 400);
    }

    // email_confirm skips the verification email: the admin is vouching for the
    // address, and passkey registration requires a confirmed account.
    //
    // provisioned_by_admin is what the on_auth_user_created trigger looks for
    // to decide whether the account starts active and may hold the admin role.
    // Anyone who self-registers lacks it and lands deactivated.
    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: {
        full_name: fullName,
        staff_id: staffId,
        role,
        provisioned_by_admin: true,
      },
    });

    if (createError) {
      const message = createError.message.match(/already (been )?registered/i)
        ? "An account with that email already exists."
        : createError.message;
      return json({ error: message }, 400);
    }

    // The on_auth_user_created trigger seeds the profile; make sure the values
    // landed even if the metadata was shaped unexpectedly. The admin has seen
    // this password, so it stays a shared secret until the staff member picks
    // their own, which is what must_change_password forces.
    await admin
      .from("profiles")
      .update({
        full_name: fullName,
        email,
        staff_id: staffId || null,
        role,
        is_active: true,
        must_change_password: true,
      })
      .eq("id", created.user.id);

    return json({
      user_id: created.user.id,
      email,
      full_name: fullName,
      role,
      temporary_password: password,
    });
  }

  if (action === "reset_password") {
    const userId = String(body.user_id ?? "");
    if (!userId) {
      return json({ error: "A user id is required." }, 400);
    }

    const password = String(body.password ?? "").trim() || generatePassword();
    if (password.length < 8) {
      return json({ error: "Passwords must be at least 8 characters." }, 400);
    }

    const { error } = await admin.auth.admin.updateUserById(userId, { password });
    if (error) {
      return json({ error: error.message }, 400);
    }

    await admin
      .from("profiles")
      .update({ must_change_password: true })
      .eq("id", userId);

    return json({ user_id: userId, temporary_password: password });
  }

  if (action === "delete") {
    const userId = String(body.user_id ?? "");
    if (!userId) {
      return json({ error: "A user id is required." }, 400);
    }
    if (userId === caller.user.id) {
      return json({ error: "You cannot delete your own account." }, 400);
    }

    const { count: remainingAdmins } = await admin
      .from("profiles")
      .select("id", { count: "exact", head: true })
      .eq("role", "admin")
      .eq("is_active", true)
      .neq("id", userId);

    if ((remainingAdmins ?? 0) === 0) {
      return json(
        { error: "There must be at least one active administrator." },
        400,
      );
    }

    const { error } = await admin.auth.admin.deleteUser(userId);
    if (error) {
      const raw = error.message ?? "";
      const message = /permission denied|database error|unexpected failure/i
          .test(raw)
        ? "That account could not be deleted. Try again, and contact your "
          + "administrator if it keeps happening."
        : raw;
      return json({ error: message }, 400);
    }

    return json({ user_id: userId, deleted: true });
  }

  return json({ error: `Unknown action: ${action}` }, 400);
});
