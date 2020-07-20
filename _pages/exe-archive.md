---
title: "운동"
permalink: /exe/
layout: category
author_profile: true
exe_tag: ["routine"]
---
{% include group-by-array collection=site.posts field="tags" %}

{% for exeTag in page.exe_tag %}
{% for tag in group_names %}
{% if exeTag == tag %}
<h2 id="{{ tag | slugify }}" class="archive__subtitle">{{ tag }}</h2>
{% assign posts = group_items[forloop.index0] %}
{% for post in posts %}
{% assign category = post.categories %}
{% if category[0] == 'exe' %}
{% include archive-single.html %}
{% endif %}
{% endfor %}
{% endif %}
{% endfor %}
{% endfor %}