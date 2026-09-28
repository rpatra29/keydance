# Vocabulary attribution

The bundled benchmark vocabulary is a filtered subset of `word_count.txt` from
[`brekker23/English-word-frequencies`](https://github.com/brekker23/English-word-frequencies).
The source repository is licensed under Apache License 2.0 and derives its word
counts from public-domain books.

Keydance keeps only source entries that are already lowercase alphabetic words
of 2–12 characters, removes
entries in `denied_terms.txt`, and takes the first 1,000 remaining entries in
frequency order. The list is bundled so the app never needs network access.
