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

# Array of separate queries
queries=( "bugbounty" "bug-bounty" "bug bounty" )

# Counters
repos_analyzed=0
repos_retrieved=0
pages_processed=0

# We'll track consecutive empty pages *per query.*
# If a query hits 3 in a row, we skip the rest of its pages.
# Then move on to the next query in the array.
consecutive_empty_for_query=0

# Remove any old README
rm -f README.md

# Write out initial portion of README
cat <<EOF > README.md
# **BountyHound**

**BountyHound** is your daily tracker for top GitHub repositories related to **bug bounty**. By monitoring and curating trending repositories, BountyHound ensures you stay up-to-date with the latest tools, frameworks, and research in the bug bounty domain.

---

## **How It Works**

- **Multiple Queries**: We search separately for "bugbounty", "bug-bounty", and "bug bounty."
- **Automated Updates**: Leveraging GitHub Actions to automatically fetch and update this list.
- **Key Metrics**: Repositories with their stars, forks, descriptions, and last updated date.
- **Duplicates**: If a repo appears in multiple queries, it will be listed multiple times.

---

## **Summary of Today's Analysis**

| Metric                    | Value                   |
|---------------------------|-------------------------|
| Execution Date            | $(date '+%Y-%m-%d %H:%M:%S') |
| Repositories Analyzed     | <REPOS_ANALYZED>       |
| Repositories Retrieved    | <REPOS_RETRIEVED>      |
| Pages Processed           | <PAGES_PROCESSED>      |
| Duplicate Repos?         | Yes                     |

---

## **Top Bug Bounty Repositories (Updated: $(date '+%Y-%m-%d'))**

| Repository (Link) | Stars   | Forks   | Description                     | Last Updated |
|-------------------|---------|---------|---------------------------------|--------------|
EOF

# Function to fetch & append results for a single query
fetch_and_append() {
    local query="$1"

    echo -e "${YELLOW}Fetching repository information for: ${GREEN}${query}${NC}"
    
    # 1) First fetch just 1 page (up to 5 items) to get total_count
    local initial_response
    initial_response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/search/repositories?q=$(echo "$query" | sed 's/ /+/g')&sort=stars&order=desc&per_page=5")

    # Check validity
    if ! echo "$initial_response" | jq -e . > /dev/null 2>&1; then
        echo -e "${RED}Error: Failed to fetch data from GitHub API for '$query'.${NC}"
        return
    fi

    local total_count
    total_count=$(echo "$initial_response" | jq -r '.total_count // 0')
    if [[ "$total_count" -eq 0 ]]; then
        echo -e "${RED}No repositories found for '$query'.${NC}"
        return
    fi

    # Calculate pages needed
    local pages
    pages=$(( (total_count + 99) / 100 ))

    # Reset consecutive empty pages *for this query*
    consecutive_empty_for_query=0

    # 2) Loop over pages
    for (( page=1; page<=pages; page++ )); do
        pages_processed=$((pages_processed + 1))

        local response
        response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
            "https://api.github.com/search/repositories?q=$(echo "$query" | sed 's/ /+/g')&sort=stars&order=desc&per_page=100&page=$page")

        # Check if response is valid
        local item_count
        item_count=$(echo "$response" | jq '.items | length')
        if [[ "$item_count" -eq 0 || "$item_count" == "null" ]]; then
            consecutive_empty_for_query=$((consecutive_empty_for_query + 1))
            if [[ $consecutive_empty_for_query -ge 3 ]]; then
                # skip remaining pages for this query
                echo -e "${YELLOW}Hit 3 consecutive empty pages for '$query'. Skipping further pages...${NC}"
                break
            fi
            continue
        else
            consecutive_empty_for_query=0
        fi

        # Append items to README
        while read -r line; do
            repos_analyzed=$((repos_analyzed + 1))

            local name
            local owner
            local stars
            local forks
            local desc
            local updated
            local url

            name=$(echo "$line" | jq -r '.name // "Unknown"')
            owner=$(echo "$line" | jq -r '.owner.login // "Unknown"')
            stars=$(echo "$line" | jq -r '.stargazers_count // 0')
            forks=$(echo "$line" | jq -r '.forks_count // 0')
            desc=$(echo "$line" | jq -r '.description // "No description"')
            updated=$(echo "$line" | jq -r '.updated_at // "1970-01-01T00:00:00Z"')
            url=$(echo "$line" | jq -r '.html_url // "#"')

            repos_retrieved=$((repos_retrieved + 1))

            local short_desc
            short_desc=$(echo "$desc" | cut -c 1-50)
            if [ ${#desc} -gt 50 ]; then
                short_desc="$short_desc..."
            fi

            # Convert updated date to YYYY-MM-DD
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

        done < <(echo "$response" | jq -c '.items[]')
    done
}

#
# MAIN: Run the 3 queries, appending results
#
for kw in "${queries[@]}"; do
    fetch_and_append "$kw"
done

#
# Replace placeholders
#
sed -i "s/<REPOS_ANALYZED>/$repos_analyzed/" README.md
sed -i "s/<REPOS_RETRIEVED>/$repos_retrieved/" README.md
sed -i "s/<PAGES_PROCESSED>/$pages_processed/" README.md

# Debug prints (optional)
echo "DEBUG: Repositories Analyzed  : $repos_analyzed"
echo "DEBUG: Repositories Retrieved : $repos_retrieved"
echo "DEBUG: Pages Processed        : $pages_processed"

# Commit and push if README changed
if [ -s README.md ]; then
    git config --global user.email "github-actions@github.com"
    git config --global user.name "GitHub Actions Bot"
    git add README.md
    git commit -m "Update README with bug bounty repositories for 3 separate queries"
    git push origin main
fi
