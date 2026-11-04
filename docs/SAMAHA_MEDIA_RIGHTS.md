# Samaha portraits — permission declaration and remaining limitations

Date: 2026-11-02.

The requester was explicitly asked how to handle the **26 original photographs**
with reviewed name/role/image-card associations but no documented reuse rights.
The selected answer was **“لدي إذن باستخدام الصور” / “I have permission to use the photos.”**
No custom response, permission document, licensing URL, rights-holder identity,
or detailed licence terms were supplied.

This is recorded as a **user declaration**, not independent verification, a
public-domain finding, an open licence, or proof that publication grants rights.
The integration displays these 26 source-attributed portraits on that declaration.
`rights_status` remains `unverified`; `isPermitted` remains false. The separately
labelled reference-display path requires `display_policy: user_declared_permission`
and non-empty `permission_evidence`, as well as the reviewed portrait association,
exact subject-name binding, HTTPS source host, safe local path and evidence hashes.
Unknown rights without this explicit declaration fail closed.

**Hassan Ali and Sherif El-Sebaie remain without photographs** because their
image/name associations conflict. Permission does not resolve an identity conflict.
Their original source URLs remain in the people records and review evidence.
No random, generated or unrelated substitute photographs are used.

Before any public release, the owner should retain the actual permission document,
verify its scope and resolve the two association conflicts. This task did not deploy,
publish, upload to a public host or change production services.

## Content authority

`assets/data/samaha/` contains the nine authoritative runtime JSON documents.
The typed Dart model/repository validates them. Review manifests, archived HTML,
old source ledgers and generation scripts are **historical evidence**, not a second
runtime dataset and must not be replayed over the reviewed data without a new review.
Editorial profiles are not platform lawyer accounts, auth users, bookings or credentials.
