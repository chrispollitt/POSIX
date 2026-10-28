#!/usr/bin/env python3
import sys
import argparse
import re
from unidecode import unidecode
import emoji

# 1. Define your custom Emoji-to-ASCII dictionary.
EMOJI_TO_ASCII = {
    ':red_heart:': '<3',
    ':heart:': '<3',
    ':thumbs_up:': '(y)',
    ':thumbsup:': '(y)',
    ':ok_hand:': '(ok)',
    ':slightly_smiling_face:': ':)',
    ':grinning_squinting_face:': 'XD',
    ':fire:': '(flame)',
    ':star:': '*',
    ':hundred_points:': '100',
}

def smart_to_ascii(text, clean=False):
    # Step A: Convert emojis to their text aliases
    text_with_aliases = emoji.demojize(text)
    
    # Step B: Replace aliases with custom ASCII art/text
    for alias, ascii_rep in EMOJI_TO_ASCII.items():
        text_with_aliases = text_with_aliases.replace(alias, ascii_rep)
        
    # Step C: Transliterate the remaining non-ASCII text
    final_ascii = unidecode(text_with_aliases)
    
    # Step D: Strip non-whitespace control characters if requested
    if clean:
        # This regex matches ASCII/Unicode control characters EXCEPT:
        # \x09 (Tab), \x0a (Newline/LF), \x0d (Carriage Return/CR)
        # It also catches C1 controls (\x80-\x9f) just in case.
        final_ascii = CONTROL_CHARS_RE.sub('', final_ascii)
        
    return final_ascii

# Pre-compile the regex for performance
# Ranges: 00-08, 0b-0c, 0e-1f, 7f-9f
CONTROL_CHARS_RE = re.compile(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]')

def main():
    # Set up command-line argument parsing
    parser = argparse.ArgumentParser(description="Convert UTF-8 to 7-bit ASCII, with optional control char cleaning.")
    parser.add_argument('-c', '--clean', action='store_true', 
                        help="Strip non-whitespace control characters (e.g., backspace, DEL).")
    args = parser.parse_args()

    # Read from stdin, process, and write to stdout
    for line in sys.stdin:
        cleaned_line = smart_to_ascii(line, clean=args.clean)
        sys.stdout.write(cleaned_line)

if __name__ == '__main__':
    main()