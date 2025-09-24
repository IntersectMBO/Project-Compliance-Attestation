# Project-Compliance-Attestation
This is a script that runs compliance checks for projects in Tooling Program

# Script Name

This scripts performs a self-attestation on the owner/repo.e.g. cardano-foundation/cardano-wallet

## Setup

### Set up github token with readonly permissions

You can generate a GitHub personal access token (classic or fine-grained) with read-only permissions by restricting its scope. Here’s how:

#### Instructions on Option 1 

🔹 Fine-grained personal access token (recommended) 

- Fine-grained tokens are more secure and allow setting read-only permissions explicitly.

- Go to GitHub Settings → Developer settings → Personal access tokens → Fine-grained tokens
- Click Generate new token.
 - Fill in:
 - Token name → something descriptive like readonly-token.
 - Expiration → set a time limit (best practice).
 - Repository access → choose "Only select repositories" (or "All repositories" if you want broader read-only access).
  - Permissions → expand and select Read-only for:
  - Contents (so you can clone / pull code but not push).
  - Metadata (usually required for basic repo info).
  - Any other resource you need (issues, actions, etc.) → set to Read-only only.

 - Click Generate token.
  - Copy and save the token — you won’t be able to view it again.
  - Consider storing this so you can initialise an environment variable called GH_TOKEN 
  - e.g. export GH_TOKEN = "hjsdhf&jhjsdhf###jhhj"
  - Usage : Usage example (for HTTPS clone/pull):
   - git clone https://<YOUR_TOKEN>@github.com/owner/repo.git

#### Instructions on Option 2 

🔹 Classic personal access token (less granular)

 - Go to GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)
 - Click Generate new token (classic).
 - Give it a name and expiration date.
 - Select only read-only scopes:
 - For code access: check repo → Public Repo (for public repos only).
 - For private repos: you must check repo, but classic tokens don’t allow strict read-only — they always include write permissions.
 - This is why fine-grained tokens are recommended.
 - Generate and copy the token.
 - Consider storing this so you can initialise an environment variable called GH_TOKEN 
  - e.g. export GH_TOKEN = "hjsdhf&jhjsdhf###jhhj"
  - use this in your script
 * Outcome * : this ensures only read access is available 


### Unset your Github Token and set to you readonly token

- @MyMachine:~/projects/intersect$ unset GH_TOKEN
 - @MyMachine:~/projects/intersect$ gh auth login
 - ? Where do you use GitHub? GitHub.com
 - ? What is your preferred protocol for Git operations on this host? SSH
 - ? Upload your SSH public key to your GitHub account? Skip
 - ? How would you like to authenticate GitHub CLI? Paste an authentication token
 - Tip: you can generate a Personal Access Token here https://github.com/settings/tokens
 - The minimum required scopes are 'repo', 'read:org'.
 - ? Paste your authentication token: ****************************************


### Instructions to install or run.
- Setup
  - initialise you github per above  'Unset your Github ... '  
 - Get the script from Intersect 
  - clone the repo per below to get the self-attest script
  -- gh repo clone IntersectMBO/Open-Source-Office *or*
  -- just download as a zip and unpack
  - confirm repo status 
   - git status 
  - ensure the script has +x executable permissions
    - chmod +x intersect_ost_self_attest.sh
  - run the script
    - now run the script as below (noting if you wish to have 180 days window, change 30 below to 180)
    - ./intersect_ost_self_attest.sh input-output-hk/daedalus --out io_da_attest.pdf --days 30
    - the output should include output locations myuserdir and runninghere (for example)
    - output is html, pdf and markdown
     - ==============================================
     -  [OUTPUT] Working directory : /home/myuserdir/runninghere
     -  [OUTPUT] HTML report       : /home/myuserdir/runninghere/io_da_attest.html
     -  [OUTPUT] PDF report        : /home/myuserdir/runninghere/io_da_attest.pdf
     -  [OUTPUT] Markdown summary  : /home/myuserdir/runninghere/io_da_attest.md
     -  ==============================================


## Usage

    - ./intersect_ost_self_attest.sh input-output-hk/daedalus --out io_da_attest.pdf --days 30

## License

MIT / Apache-2.0 / etc.

