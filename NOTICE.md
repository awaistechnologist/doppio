# Licensing notes

Doppio is released under the **PolyForm Noncommercial License 1.0.0**
(see `LICENSE`). Commercial use requires a separate paid licence, available from
muhammad.awais.tahir@gmail.com.

## What the licence permits

| Use | Status |
|---|---|
| Personal use, hobby projects, study, private experimentation | Free |
| Charity, school, university, public research, government body | Free |
| Company or other for-profit organisation | **Paid licence required** |
| Paid consultancy or contract work | **Paid licence required** |
| Any product or service that is sold, hosted, or advertised | **Paid licence required** |
| Forks and modifications for noncommercial purposes | Permitted, with attribution |

Doppio is therefore **source-available, not open source**: the source can be
read, built and modified, but commercial use is reserved.

## Why PolyForm, and what it does not do

PolyForm Noncommercial is professionally drafted and widely recognised, which
matters for a licence intended to be enforced. It does not draw the line exactly
at "every organisation pays": by long-standing convention, charities, schools and
government bodies count as noncommercial and use it free. PolyForm *Strict*
contains the same carve-out — it only removes redistribution rights — so
switching to it would not change that.

A licence that charges every organisation would mean the **Business Source
License 1.1**, which is designed to be parameterised with a custom "Additional
Use Grant". BSL also mandates a Change Date on which the software becomes open
source, typically two to four years out. That trade was considered and declined:
for a Mac utility, the institutions that would otherwise have paid are few, and
the goodwill is worth more.

PolyForm permitting noncommercial redistribution also resolves a practical
problem: GitHub's Terms of Service grant every user the right to fork a public
repository, which a no-redistribution licence would contradict.

## The compatibility database

`compat-db/rules.json` ships under the same licence as the rest of the project.
It records which flag isolates which application — accumulated
reverse-engineering rather than creative work, and the part of the project most
useful to a competitor. Contributors can still share rules, because
noncommercial redistribution is permitted.

Placing that one file under CC0-1.0 would additionally allow commercial reuse of
the data, which is the usual choice for datasets that depend on outside
contributions. That is a deliberate trade of control for contributions, and the
current answer is to keep control.

## Third-party applications

Doppio generates launchers for applications it does not own; those applications
remain under their own licences. `LICENSE` sets out what Doppio does and does not
do to them, including what a cloned Shot actually is.
