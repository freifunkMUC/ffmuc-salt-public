<?php

/**
 * Links to the club's imprint and privacy policy in the login footer.
 * $config['legal_links'] = ['Impressum' => 'https://…', 'Datenschutz' => 'https://…'];
 */
class legal_links extends rcube_plugin
{
    public $task = 'login|logout';

    public function init()
    {
        $links = [];
        foreach ((array) rcube::get_instance()->config->get('legal_links', []) as $label => $url) {
            $links[] = html::a(['href' => $url, 'target' => '_blank', 'rel' => 'noopener'], rcube::Q($label));
        }
        if ($links) {
            // A line of its own; a div would get Elastic's grey footer box.
            $this->api->add_content(html::p(['class' => 'legal-links', 'style' => 'margin: .25rem 0 0'],
                implode('&nbsp;&bull;&nbsp;', $links)), 'loginfooter');
        }
    }
}
