=====================================================================
  PROJECT AERIA — PERSONAL VAULT
  AES-256 Encrypted Document Storage
=====================================================================

---------------------------------------------------------------------
DISCLAIMER
---------------------------------------------------------------------
Encryption only protects data as well as the passphrase and handling
behind it. There is no backdoor and no recovery mechanism built into
this system — if a passphrase is lost or forgotten, the encrypted
contents are permanently unrecoverable.

This vault is provided "as is," with no warranty. You are responsible
for choosing a strong, memorable passphrase, storing it safely and
separately from the drive itself, and testing that encryption and
decryption both work on your target machines before relying on this
vault to hold anything you cannot afford to lose.

This directory contains encrypted personal and family documents.
Files with the .gpg extension are AES-256 encrypted.

NO PLAINTEXT SENSITIVE DATA IS STORED HERE.
If you find a plaintext file in this directory that contains
sensitive information, encrypt and shred it immediately using
the instructions below.

---------------------------------------------------------------------
CONTENTS
---------------------------------------------------------------------

  family/         Identification, family records, photographs
  medical/        Medical history, prescriptions, vaccination records
  legal/          Wills, deeds, contracts, insurance policies
  credentials/    Passwords, account numbers, access codes

---------------------------------------------------------------------
SETUP (FIRST TIME)
---------------------------------------------------------------------

  Requires: GPG (gnupg)
    Linux:  sudo apt install gnupg
    macOS:  brew install gnupg
    Windows: https://www.gpg4win.org/

  Run once to verify the vault is working:
    ./vault.sh init

---------------------------------------------------------------------
ENCRYPTING A FILE
---------------------------------------------------------------------

  Basic:
    ./vault.sh add /path/to/document.pdf

  With category and original shredding:
    ./vault.sh add /path/to/passwords.txt \
      --category credentials \
      --name passwords_2025 \
      --shred

  --shred overwrites the original file with zeros before deleting.
  Use it once you have confirmed the encrypted copy is readable.

---------------------------------------------------------------------
READING AN ENCRYPTED FILE
---------------------------------------------------------------------

  ./vault.sh get passwords_2025 --category credentials

  The decrypted file is written to /tmp (RAM only).
  It is printed to the screen and disappears on reboot.

  To remove it immediately after use:
    ./vault.sh wipe-tmp

---------------------------------------------------------------------
VERIFYING THE VAULT
---------------------------------------------------------------------

  Test that all files can be decrypted (no plaintext written):
    ./vault.sh verify

  Run this after any major hardware change or before committing
  the drive to long-term cold storage.

---------------------------------------------------------------------
PASSPHRASE GUIDANCE
---------------------------------------------------------------------

  Your passphrase is the ONLY key to this vault.
  It is never stored anywhere on this system.

  Choose a passphrase that:
    - Is at least 6 words long (diceware / random words)
    - You can memorise
    - Is not used anywhere else

  Store a paper copy in a physically secure location separate
  from this drive. If the passphrase is lost, the data is
  unrecoverable.

---------------------------------------------------------------------
ENCRYPTION PARAMETERS
---------------------------------------------------------------------

  Algorithm:       AES-256 (symmetric)
  Key derivation:  SHA-512, iterated salted (65536 rounds)
  Tool:            GnuPG (gpg / gpg2)

  These parameters meet or exceed the requirements for protecting
  sensitive personal data at rest.

---------------------------------------------------------------------
COLD STORAGE CHECKLIST
---------------------------------------------------------------------

  Before writing this vault to M-DISC or other archival media:

  [ ] Run ./vault.sh verify — confirm all files decrypt correctly
  [ ] Run ./vault.sh list   — confirm all expected files are present
  [ ] Confirm passphrase is memorised AND written on paper copy
  [ ] Paper copy stored separately from this drive
  [ ] Run ./vault.sh wipe-tmp — remove any /tmp decrypted files

=====================================================================
