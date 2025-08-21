#!/bin/bash

set -e

HUJSON_FILE="$1"
JSON_FILE="$2"

if [ -z "$HUJSON_FILE" ]; then
    echo "Error: HuJSON file path is required as first argument" >&2
    exit 1
fi

if [ -z "$JSON_FILE" ]; then
    echo "Error: Output JSON file path is required as second argument" >&2
    exit 1
fi

if [ ! -f "$HUJSON_FILE" ]; then
    echo "Error: HuJSON file '$HUJSON_FILE' does not exist" >&2
    exit 1
fi

echo "Converting $HUJSON_FILE to $JSON_FILE"

# Use Python to properly parse HuJSON and convert to JSON
python3 << EOF > "$JSON_FILE"
import json
import re
import sys

def convert_hujson_to_json(hujson_content):
    # Remove line comments
    lines = hujson_content.split('\n')
    cleaned_lines = []
    for line in lines:
        # Remove // comments but preserve strings that contain //
        in_string = False
        escaped = False
        comment_start = -1
        
        for i, char in enumerate(line):
            if escaped:
                escaped = False
                continue
            if char == '\\\\' and in_string:
                escaped = True
                continue
            if char == '"' and not escaped:
                in_string = not in_string
                continue
            if not in_string and char == '/' and i + 1 < len(line) and line[i + 1] == '/':
                comment_start = i
                break
        
        if comment_start >= 0:
            cleaned_lines.append(line[:comment_start].rstrip())
        else:
            cleaned_lines.append(line)
    
    # Join lines and remove trailing commas
    content = '\n'.join(cleaned_lines)
    # Remove trailing commas before } or ]
    content = re.sub(r',(\s*[}\]])', r'\1', content)
    
    return content

try:
    with open('$HUJSON_FILE', 'r') as f:
        hujson_content = f.read()
    
    json_content = convert_hujson_to_json(hujson_content)
    
    # Parse and pretty-print to ensure valid JSON
    parsed = json.loads(json_content)
    print(json.dumps(parsed, indent=2))
    
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF

if [ $? -eq 0 ]; then
    echo "Successfully converted HuJSON to JSON"
    echo "Output file: $JSON_FILE"
else
    echo "Error: Failed to convert HuJSON to valid JSON" >&2
    exit 1
fi