# File download (Export to File)

Automatically downloaded files (without dialogue) will be stored in the browser-use temp directory (e.g. `/private/tmp/browser-use-downloads-*/`).

The `BrowserSession` object has a property `downloaded_files(self) -> list[str]` containing a list of absolute file paths to downloaded files in this session. 

## Custom script

In a custom script, you can override the download path when creating the browser object: `browser = Browser(downloads_path='~/Downloads/tmp')`
