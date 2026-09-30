# Vocabulary attribution

Keydance bundles
[`frequency_dictionary_en_82_765.txt`](https://github.com/wolfgarbe/SymSpell/blob/master/SymSpell/frequency_dictionary_en_82_765.txt)
from the official [SymSpell repository](https://github.com/wolfgarbe/SymSpell).
The file combines Google Books Ngram frequencies with SCOWL vocabulary
filtering, producing roughly 80,000 common English terms with frequencies for
ranking correction candidates.

The dictionary is loaded locally at launch and is never modified or sent over
the network. See the upstream repository for the source-data licenses and
generation details.
