rspamd_config:register_symbol{
    name = "KITS_HEADER_GOOGLE_GROUP",
    score = 0.1,
    group = "headers",
    description = "Message contains X-Google-Group-Id header or List-Unsubscribe header with googlegroups",
    callback = function(task)
      -- Check for X-Google-Group-Id header
      if task:get_header('X-Google-Group-Id') then
        return true
      end
      
      -- Check for List-Unsubscribe header containing 'googlegroups'
      local list_unsubscribe = task:get_header('List-Unsubscribe')
      if list_unsubscribe and string.find(list_unsubscribe:lower(), 'googlegroups') then
        return true
      end
      
      return false
    end
}
