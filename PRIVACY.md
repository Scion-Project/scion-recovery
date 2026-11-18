<!-- SPDX-License-Identifier: MIT-0 -->
# Privacy: crash and boot reports

Crash and boot reporting is **planned and opt-in**. It is not in any Scion build yet. This page says what it
would do, so that it can be checked against the code when it ships.

## The question

The installer asks one question: **"Send anonymous crash and boot reports to help Scion? Yes / No"**.
The answer can be changed later. Nothing is sent unless the answer is Yes.

## What a report contains

- A summary of a crash or a boot: what failed, and where.
- The build's hashes, so a report can be matched to the image that made it.
- The phone model.
- A random install ID.

Nothing else is in a report.

## What is removed on the phone first

Before a report leaves the phone, it is scrubbed there of:

- serial numbers and the IMEI;
- MAC and Bluetooth addresses;
- Wi-Fi network names;
- IP addresses;
- email addresses and phone numbers;
- location;
- anything else that identifies the device.

## Where it goes, and how long it is kept

Reports are sent over HTTPS to `https://claudiusthebot.duckdns.org/scion/report`.

The server does not store IP addresses. Reports are deleted after 90 days.
