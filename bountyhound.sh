#!/bin/bash

# Set up color variables
YELLOW='\033[1;93m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Fetch GitHub Token from environment variable
if [[ -z "$PAT_TOKEN" ]]; then
    echo -e "${RED}Error: PAT_TOKEN environment variable is not set. Exiting.${NC}"
    exit 1
fi

GITHUB_TOKEN="$PAT_TOKEN"

# Start execution time tracking
start_time=$(date +%s)

# Check rate limit
rate_limit_response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/rate_limit")
remaining=$(echo "$rate_limit_response" | jq -r '.rate.remaining // 0')
reset_time=$(echo "$rate_limit_response" | jq -r '.rate.reset // 0')

if [[ "$remaining" -eq 0 ]]; then
    reset_time_human=$(date -d "@$reset_time" "+%Y-%m-%d %H:%M:%S")
    echo -e "${RED}Rate limit exceeded. Try again after: $reset_time_human${NC}"
    exit 1
fi

# ------------------------------------------------------------------
#        COOL REPO NAME: BountyHound
# ------------------------------------------------------------------

# Hardcoded “topic” or rather our search query
# We encode it manually: stars%3A%3E50+%28bugbounty+OR+bug-bounty+OR+%22bug+bounty%22%29+sort%3Astars
encoded_query="stars%3A%3E50+%28bugbounty+OR+bug-bounty+OR+%22bug+bounty%22%29+sort%3Astars"

# We'll fetch 5 results to get total_count, then we fetch 100 per page
echo -e "${YELLOW}Fetching repository information for: ${GREEN}bugbounty, bug-bounty, bug bounty${NC}"
response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/search/repositories?q=$encoded_query&per_page=5")

# Validate the API response
if ! echo "$response" | jq -e . > /dev/null 2>&1; then
    echo -e "${RED}Error: Failed to fetch data from GitHub API. Please check your internet connection or GitHub token.${NC}"
    exit 1
fi

# Extract total count and validate
tpc=$(echo "$response" | jq -r '.total_count // 0')
if [[ "$tpc" -eq 0 ]]; then
    echo -e "${RED}No repositories found for bug bounty keywords.${NC}"
    exit 1
fi

# Calculate pages needed (100 items per page)
pg=$(( (tpc + 99) / 100 ))

# Initialize counters
repos_analyzed=0
repos_retrieved=0
pages_processed=0
empty_pages=0

# Remove any old README
rm -f README.md

# Write out the initial portion of README
cat <<EOF > README.md
# **BountyHound**

**BountyHound** is your daily tracker for the top GitHub repositories related to **bug bounty**. By monitoring and curating trending repositories, BountyHound ensures you stay up-to-date with the latest tools, frameworks, and research in the bug bounty domain.

---

## **How It Works**

- **Automated Updates**: BountyHound leverages GitHub Actions to automatically fetch and update the list of top bug bounty repositories daily.
- **Key Metrics Tracked**: The list highlights repositories with their stars, forks, and concise descriptions to give a quick overview of their relevance.
- **Focus on Bug Bounty**: Only repositories tagged or associated with bug bounty topics are included, ensuring highly focused and useful results.
- **Rich Metadata**: Provides information like repository owner, project description, and last updated date to evaluate projects at a glance.

---

## **Summary of Today's Analysis**

| Metric                    | Value                   |
|---------------------------|-------------------------|
| Execution Date            | $(date '+%Y-%m-%d %H:%M:%S') |
| Repositories Analyzed     | <REPOS_ANALYZED>       |
| Repositories Retrieved    | <REPOS_RETRIEVED>      |
| Pages Processed           | <PAGES_PROCESSED>      |
| Consecutive Empty Pages   | <EMPTY_PAGES>          |

---

## **Top Bug Bounty Repositories (Updated: $(date '+%Y-%m-%d'))**

| Repository (Link) | Stars   | Forks   | Description                     | Last Updated |
|-------------------|---------|---------|---------------------------------|--------------|
EOF

# Iterate through each page
for i in $(seq 1 "$pg"); do
    pages_processed=$((pages_processed + 1))

    page_response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/search/repositories?q=$encoded_query&per_page=100&page=$i")

    # Check if the page has items
    item_count=$(echo "$page_response" | jq '.items | length')
    if [[ "$item_count" -eq 0 || "$item_count" == "null" ]]; then
        empty_pages=$((empty_pages + 1))
        # Stop if we see 3 consecutive empty pages
        if [[ $empty_pages -ge 3 ]]; then
            break
        fi
        continue
    else
        empty_pages=0
    fi

    # Read items in the current shell so our counters update
    while read -r line; do
        repos_analyzed=$((repos_analyzed + 1))

        name=$(echo "$line" | jq -r '.name // "Unknown"')
        owner=$(echo "$line" | jq -r '.owner.login // "Unknown"')
        stars=$(echo "$line" | jq -r '.stargazers_count // 0')
        forks=$(echo "$line" | jq -r '.forks_count // 0')
        desc=$(echo "$line" | jq -r '.description // "No description"')
        updated=$(echo "$line" | jq -r '.updated_at // "1970-01-01T00:00:00Z"')
        url=$(echo "$line" | jq -r '.html_url // "#"')

        repos_retrieved=$((repos_retrieved + 1))

        short_desc=$(echo "$desc" | cut -c 1-50)
        if [ ${#desc} -gt 50 ]; then
          short_desc="$short_desc..."
        fi

        # Convert updated date to YYYY-MM-DD (UTC)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            updated_date=$(echo "$updated" | \
                           awk '{print $1}' | \
                           xargs -I {} date -u -jf "%Y-%m-%dT%H:%M:%SZ" {} "+%Y-%m-%d")
        else
            updated_date=$(date -d "$updated" "+%Y-%m-%d")
        fi

        printf "| [%s](%s) | %-7s | %-7s | %-31s | %-12s |\n" \
               "$name" "$url" "$stars" "$forks" "$short_desc" "$updated_date" \
               >> README.md

    done < <(echo "$page_response" | jq -c '.items[]')
done

# Replace placeholders
sed -i "s/<REPOS_ANALYZED>/$repos_analyzed/" README.md
sed -i "s/<REPOS_RETRIEVED>/$repos_retrieved/" README.md
sed -i "s/<PAGES_PROCESSED>/$pages_processed/" README.md
sed -i "s/<EMPTY_PAGES>/$empty_pages/" README.md

# Debug prints (optional)
echo "DEBUG: Repositories Analyzed  : $repos_analyzed"
echo "DEBUG: Repositories Retrieved : $repos_retrieved"
echo "DEBUG: Pages Processed        : $pages_processed"
echo "DEBUG: Consecutive Empty Pages: $empty_pages"

# Commit and push if README changed
if [ -s README.md ]; then
    git config --global user.email "github-actions@github.com"
    git config --global user.name "GitHub Actions Bot"
    git add README.md
    git commit -m "Update README with bug bounty repositories"
    git push origin main
fi
