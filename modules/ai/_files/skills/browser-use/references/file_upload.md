# File upload (Import from File)

The standard browseruse `input` command does not work for `<input type="file">` elements. Use CDP (Chrome DevTools Protocol) to set the file programmatically:

```bash
./scripts/browser-use.sh python "
elem = browser._run(browser._session.get_element_by_index(<FILE_INPUT_INDEX>))
target_info = browser._run(browser._session.get_current_target_info())
main_client = browser._session.cdp_client
attach_result = browser._run(main_client.send_raw('Target.attachToTarget', {'targetId': target_info['targetId'], 'flatten': True}))
sid = attach_result['sessionId']
browser._run(main_client.send_raw('DOM.setFileInputFiles', {'files': ['<ABSOLUTE_PATH_TO_JSON>'], 'backendNodeId': elem.backend_node_id}, session_id=sid))
print('done')
"
```

Replace `<FILE_INPUT_INDEX>` with the index of the file input from `./scripts/browser-use.sh state` and `<ABSOLUTE_PATH_TO_JSON>` with the absolute path to the JSON file.
