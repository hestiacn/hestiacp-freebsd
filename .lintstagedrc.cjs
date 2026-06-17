module.exports = {
	'*.md': 'markdownlint-cli2 --fix',
	'*.css': 'stylelint --fix --allow-empty-input',
	'*.{ts,js}?(x)': 'eslint --fix',
	'*.{json,yaml,yml,html,scss,less,graphql}': 'prettier --write --ignore-unknown',
};
